# Which uploads may reach libvips (Dragonfly's, lib/dragonfly_vips.rb), by their first bytes rather than their name or
# declared type: an image library picks a format from a file's contents, and SVG, PDF and the like can read files or
# fetch URLs. DragonflyVips refuses any other loader too; this keeps them from reaching libvips at all
module ImageSignature
  FORMATS = 'JPEG, PNG, GIF, WebP or HEIC'.freeze

  # The ISO base media brands of HEIC, HEIF and AVIF stills and sequences
  HEIF_BRANDS = %w[heic heix hevc hevx heim heis mif1 msf1 avif avis].freeze

  def self.allowed?(attachment)
    head = attachment.file { |f| f.read(16) }.to_s.b
    head.start_with?("\xFF\xD8\xFF".b, "\x89PNG\r\n\x1A\n".b, 'GIF87a', 'GIF89a') ||
      (head.start_with?('RIFF') && head[8, 4] == 'WEBP') ||
      (head[4, 4] == 'ftyp' && HEIF_BRANDS.include?(head[8, 4]))
  end
end
