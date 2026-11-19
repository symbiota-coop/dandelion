# Which uploads may reach ImageMagick, by their first bytes rather than their name or declared type: ImageMagick picks
# a format from a file's contents, and SVG, PostScript, MSL and the like can read files, fetch URLs or run Ghostscript.
# config/imagemagick/policy.xml denies those too; this keeps them from reaching identify at all
module ImageSignature
  FORMATS = 'JPEG, PNG, GIF, WebP or HEIC'.freeze

  # The ISO base media brands of HEIC, HEIF and AVIF stills that ImageMagick knows by their bytes (6.9.12 and 7). It
  # doesn't know the sequence and layered brands (hevc, msf1, avis, heim...) that way, so for those it went by the
  # file's name, which is the uploader's
  HEIF_BRANDS = %w[heic heix mif1 avif].freeze

  # The format of an upload's first bytes, as the extension ImageMagick reads it by, or nil if it's none we take
  def self.format(attachment)
    head = attachment.file { |f| f.read(16) }.to_s.b
    if head.start_with?("\xFF\xD8\xFF".b) then 'jpeg'
    elsif head.start_with?("\x89PNG\r\n\x1A\n".b) then 'png'
    elsif head.start_with?('GIF87a', 'GIF89a') then 'gif'
    elsif head.start_with?('RIFF') && head[8, 4] == 'WEBP' then 'webp'
    elsif head[4, 4] == 'ftyp' && HEIF_BRANDS.include?(head[8, 4]) then head[8, 4] == 'avif' ? 'avif' : 'heic'
    end
  end

  def self.allowed?(attachment)
    !format(attachment).nil?
  end

  # Before anything runs ImageMagick on an upload: if its bytes are a format we take, points the attachment at a copy
  # named for that format and returns it, so the uploader's filename (.mp4, .svg, .docx...) can never choose the
  # coder or a delegate program, and what convert writes is named for it too. Returns nil, changing nothing, otherwise
  def self.pin_format!(attachment)
    return unless (format = format(attachment))

    copy = Dragonfly::Utils.new_tempfile(format)
    FileUtils.cp(attachment.path, copy.path)
    attachment.job.content.update(copy, 'name' => "#{SecureRandom.uuid}.#{format}")
    format
  end
end
