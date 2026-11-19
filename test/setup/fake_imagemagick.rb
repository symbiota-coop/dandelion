# Tests refuse MiniMagick (the avatar, YouTube thumbnails and imports' theme colours), so they don't need ImageMagick
# installed: stub it. Only a test of ImageMagick itself runs it, inside with_imagemagick (TestHelpers), in the CI group
# that installs it (with images). Dragonfly runs libvips (lib/dragonfly_vips.rb), in this process, which tests run
# for real, as it's fast
module FakeImageMagick
  class << self
    attr_accessor :real
  end

  # An image's format and size, from its first bytes, for a test stubbing MiniMagick
  def self.header(data)
    data = data.b
    if data.start_with?("\x89PNG".b) then ['PNG', *data[16, 8].unpack('NN')]
    elsif data.start_with?('GIF8') then ['GIF', *data[6, 4].unpack('vv')]
    elsif data.start_with?("\xFF\xD8".b) then ['JPEG', *jpeg_size(data)]
    elsif data[0, 4] == 'RIFF' && data[8, 4] == 'WEBP' then ['WEBP', 100, 100]
    elsif data[4, 8].to_s.match?(/\Aftyp(heic|heix|mif1)/) then ['HEIC', 100, 100]
    end
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

  # MiniMagick::Shell
  module RefuseMiniMagick
    def run(*, **)
      return super if FakeImageMagick.real

      raise 'A test ran MiniMagick: stub it, or check ImageMagick itself inside with_imagemagick'
    end
  end
end
MiniMagick::Shell.prepend(FakeImageMagick::RefuseMiniMagick)
