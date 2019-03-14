require "thread"
require "fftw3"
require "coreaudio"
require "socket"

# for reference: bass, midrange, & treble frequencies in octaves. range in Hz for reference.
#
#           lower range      mid range       upper range
# bass      <31 to 62 Hz     62 to 125 Hz    125 to 250 Hz
# midrange  250 to 500 Hz    500 to 1 KHz    1K to 2KHz
# treble    2K to 4KHz       4K to 8KHz      8K to 16Khz (and higher)

# easily adjustable settings:

# min,max frequency value pairs in this order: BLUE - GREEN - RED - WHITE
og_ranges = [500, 2000, 1000, 4000, 0, 200, 0, 0]

# bias modifier for each color in the LED strip -- because they dont always necessarily output the same light lvl for the same number
intensity_modifier = [1.0, 1.0, 1.0, 0.2]

# when a dominant color detected, attenuate other colors by this value. makes for cool fx
color_mask_modifier = 0.2

# friendly name for LEDs coz why not. displayed on the screen while the thing runs
friendly_name = [" BLUE", "GREEN", "  RED", "WHITE"]

# Pi server to connect to
udp_address, udp_port = '192.168.200.110', 6697

# CoreAudio interface name to hook up to. (did I mention this is OSX only?)
coreaudio_device_name = "Loopback Audio"

# buffer size for audio. also the FFT window size
BUF_SIZE = 1024

# we need this
class Numeric
  def scale_between(from_min, from_max, to_min, to_max)
    ((to_max - to_min) * (self - from_min)) / (from_max - from_min) + to_min
  end
end

# some app init done here
Thread.abort_on_exception = true

device = CoreAudio.devices.select {|i| i.name == coreaudio_device_name}.first
input_buffer = device.input_buffer(BUF_SIZE)
udp_socket = UDPSocket.new

@fft_mutex = Mutex.new
@fft_calc = nil

# hold max values here
max = [-1, -1, -1, -1]
max_overall = -1

# adjust range from 0-20kHz to fast Fourier transform sample size. then push back sample count in that range
ranges = og_ranges.map {|n| n.scale_between(0, 20000, 0, BUF_SIZE)}.each_slice(2).to_a.each {|range| range << (range[1] - range[0] + 1)}

# CTRL-C exit control
keep_going = true
Signal.trap("SIGINT") {
  keep_going = false
}

# spawn a thread to do fast fourier transform non-stop
fft_thread = Thread.start do
  input_buffer.start
  loop do
    wav = input_buffer.read(BUF_SIZE)
    @fft_mutex.synchronize do
      @fft_calc = FFTW3.fft(wav, 1).abs / (wav.length)
    end
  end
end

# aaand here we go
while keep_going

  # initial array. BGRW order because fuxxed up wiring
  run = [0, 0, 0, 0]

  f = nil
  @fft_mutex.synchronize do
    f = @fft_calc
  end
  next if f == nil

  # add freq bands together.. consolidate into ranges
  f.to_a.map(&:first)[0..BUF_SIZE].map(&:to_i).each_with_index {|v, fft_index|
    ranges.each_with_index {|range, range_index| run[range_index] += v if fft_index >= range[0] and fft_index <= range[1] and range[0] != range[1]}
  }

  # normalize for sample range size
  # run.each_with_index {|v, i| run[i] = v.fdiv(ranges[i][2])}

  # get normalized values
  run.each_with_index {|v, i| max_overall = v unless max_overall > v}
  run.each_with_index {|v, i| max[i] = v unless max[i] > v}

  # apply intensity modifier
  run.each_with_index {|v, i| run[i] *= intensity_modifier[i]}

  # color masking
  imax, vmax = -1, -1
  run.each_with_index {|v, i| vmax, imax = v, i if vmax < v}
  run.each_with_index {|v, i| run[i] = v * color_mask_modifier unless i == imax}

  # float to int conversion in 0..255 range
  run.each_with_index {|v, i| run[i] = (v * 255.0).fdiv(max[i]).to_i rescue 0}

  # update progress bars so shit looks cool
  # puts "\e[H\e[2J"
  puts "\e[0;0H"
  print "\nBroadcasting to Raspberry Pi at IP: #{udp_address} over UDP port #{udp_port}\n\n"
  run.each_with_index do |v, i|
    value = v.scale_between(0, 255, 0, 80)
    print "#{friendly_name[i]} : [#{"#" * value}#{" " * (80 - value)}] "
    print "freq: #{og_ranges[2 * i].to_s.ljust(5)}..#{og_ranges[2 * i + 1].to_s.ljust(5)} Hz, "
    print "scaling: #{intensity_modifier[i]}"
    print "\n"
  end

  # UDP SHIT gets added here
  run << run.reduce(:+) % 256 #shitty checksum that we dont even control
  run << 0x31 #just for fucks sake but we do actually check for this
  run << 0 #EOF marker

  # send it
  udp_socket.send(run.pack('C*'), 0, udp_address, udp_port)

  # sleep 1/60
end

input_buffer.stop
fft_thread.kill.join
udp_socket.close

print "\ndone - #{input_buffer.dropped_frame} frame(s) dropped at input buffer\n"