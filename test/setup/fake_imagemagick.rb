# Tests fake ImageMagick, so they don't need it installed and stay fast: Dragonfly only runs identify (format and size)
# and convert, which the fake answers from the file's header and by copying it, and refuses a file that isn't an image
# as ImageMagick's policy would. MiniMagick is refused: stub it. Only a test of ImageMagick itself runs the real one,
# inside with_imagemagick (TestHelpers), in the CI group that installs it (with images)
module FakeImageMagick
  class << self
    attr_accessor :real
  end

  def self.identify(path)
    format, width, height = header(File.binread(path, 65_536))
    raise Dragonfly::Shell::CommandFailed, "identify: no decode delegate for #{path}" unless format

    "#{format} #{width} #{height}"
  end

  def self.header(data)
    data = data.b
    if data.start_with?("\x89PNG".b) then ['PNG', *data[16, 8].unpack('NN')]
    elsif data.start_with?('GIF8') then ['GIF', *data[6, 4].unpack('vv')]
    elsif data.start_with?("\xFF\xD8".b) then ['JPEG', *jpeg_size(data)]
    elsif data[0, 4] == 'RIFF' && data[8, 4] == 'WEBP' then ['WEBP', 100, 100]
    elsif data[4, 8].to_s.match?(/\Aftyp(heic|heix|mif1)/) then ['HEIC', 100, 100]
    end
  end

  # Copies the input to the output, or writes a JPEG of its size when asked for one (-format jpeg, or a .jpg output)
  def self.convert(args)
    input = args[1...-1].map { |arg| arg.sub(/\A\w+:/, '').sub(/\[\d+\]\z/, '') }.find { |arg| File.file?(arg) }
    format, width, height = header(File.binread(input, 65_536))
    raise Dragonfly::Shell::CommandFailed, "convert: no decode delegate for #{input}" unless format

    target = args.include?('-format') ? args[args.index('-format') + 1] : File.extname(args.last).delete('.')
    if %w[jpeg jpg].include?(target.to_s.downcase) && format != 'JPEG'
      File.binwrite(args.last, jpeg(width, height))
    else
      FileUtils.cp(input, args.last)
    end
    ''
  end

  # The start and frame header of a JPEG, all identify reads
  def self.jpeg(width, height)
    "\xFF\xD8\xFF\xC0".b + [17, 8, height, width, 3].pack('nCnnC') + "\x01\x22\x00\x02\x11\x01\x03\x11\x01\xFF\xD9".b
  end

  # From the frame header (SOFn), after the segments before it
  def self.jpeg_size(data)
    index = 2
    while index + 9 < data.bytesize
      marker = data.getbyte(index + 1)
      return [data[index + 7, 2].unpack1('n'), data[index + 5, 2].unpack1('n')] if (0xC0..0xCF).cover?(marker) && ![0xC4, 0xC8, 0xCC].include?(marker)

      index += 2 + data[index + 2, 2].unpack1('n')
    end
    [1, 1]
  end

  # Dragonfly::Shell
  module Shell
    def run(command, opts = {})
      return super if FakeImageMagick.real

      args = command.shellsplit
      args.shift if File.basename(args.first) == 'magick'
      case File.basename(args.first)
      when 'identify' then FakeImageMagick.identify(args.last)
      when 'convert' then FakeImageMagick.convert(args)
      else raise "The fake ImageMagick doesn't run #{args.first}: check ImageMagick itself inside with_imagemagick"
      end
    end
  end

  # MiniMagick::Shell
  module RefuseMiniMagick
    def run(*, **)
      return super if FakeImageMagick.real

      raise 'A test ran MiniMagick: stub it, or check ImageMagick itself inside with_imagemagick'
    end
  end
end
Dragonfly::Shell.prepend(FakeImageMagick::Shell)
MiniMagick::Shell.prepend(FakeImageMagick::RefuseMiniMagick)
