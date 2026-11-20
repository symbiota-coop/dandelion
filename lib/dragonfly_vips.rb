# Dragonfly's image analysers and processors on libvips (ruby-vips), in place of its ImageMagick plugin: an app takes
# it with `plugin DragonflyVips::Plugin.new`. libvips runs in this process, reads only the header to analyse, streams
# when it resizes, and has none of ImageMagick's delegates, coders that read files or fetch URLs, or Ghostscript.
#
# It takes the same arguments as the ImageMagick plugin, as each derivative's URL and its DragonflyJob signature are
# made from them: thumb('400x400'), thumb('1920x1920>') and thumb('500x500#'), and encode('jpg', '-quality 90'). So
# URLs already out there keep working, and derivatives already stored keep being served rather than made again.
module DragonflyVips
  # The loaders allowed to read a file, named as the ImageMagick plugin's format analyser names their formats. The
  # formats ImageSignature lets through; any other loader libvips has (PDF, SVG, TIFF, raw...) is refused
  LOADERS = {
    'jpegload' => 'jpeg', 'pngload' => 'png', 'gifload' => 'gif', 'webpload' => 'webp', 'heifload' => 'heic'
  }.freeze

  # The formats processors write, by the names encode and thumb's 'format' take for them
  SAVERS = {
    'jpeg' => '.jpg', 'jpg' => '.jpg', 'png' => '.png', 'gif' => '.gif', 'webp' => '.webp', 'heic' => '.heic'
  }.freeze

  # ImageMagick's default JPEG quality where it can't read the input's, so derivatives look as they did. libvips'
  # own default is 75
  DEFAULT_QUALITY = 92

  # As the ImageMagick plugin takes them: fit in the box ('400x400', '400x', 'x300'), only shrink to fit ('>'), only
  # enlarge ('<'), and fill the box, cropping the middle ('500x500#')
  RESIZE_GEOMETRY = /\A(\d*)x(\d*)([<>]?)\z/
  CROPPED_RESIZE_GEOMETRY = /\A(\d+)x(\d+)#c?\z/
  QUALITY = /\A\s*(?:-quality (\d{1,3}))?\s*\z/

  # How wide or high thumbnail may make a side left blank ('x300'): libvips' own limit
  UNBOUNDED = 10_000_000

  # Animated GIFs and WebPs keep their frames
  ANIMATED = %w[gif webp].freeze

  class UnsupportedFormat < ArgumentError; end

  class Plugin
    def call(app, _opts = {})
      # Here rather than at boot, as requiring it loads libvips, which a machine without it fails to find
      require 'vips'

      # Turns off the loaders libvips marks as untested on untrusted input (8.13 and later), for every image
      # this process reads, not just Dragonfly's
      Vips.block_untrusted(true)

      app.add_analyser :image_properties do |content|
        DragonflyVips.properties(content)
      end
      app.add_analyser(:width) { |content| content.analyse(:image_properties)['width'] }
      app.add_analyser(:height) { |content| content.analyse(:image_properties)['height'] }
      app.add_analyser(:format) { |content| content.analyse(:image_properties)['format'] }
      app.add_analyser :aspect_ratio do |content|
        properties = content.analyse(:image_properties)
        properties['width'].to_f / properties['height']
      end
      app.add_analyser :portrait do |content|
        properties = content.analyse(:image_properties)
        properties['width'] <= properties['height']
      end
      app.add_analyser(:landscape) { |content| !content.analyse(:portrait) }
      app.add_analyser :image do |content|
        content.analyse(:image_properties)
        true
      rescue Vips::Error, UnsupportedFormat
        false
      end

      app.define(:portrait?) { portrait }
      app.define(:landscape?) { landscape }
      app.define(:image?) { image }

      app.add_processor :thumb, Thumb.new
      app.add_processor :encode, Encode.new
    end
  end

  # Width and height as displayed, after the EXIF orientation, as thumb rotates them so
  def self.properties(content)
    image = load(content)
    rotated = image.get_typeof('orientation').positive? && image.get('orientation').between?(5, 8)
    { 'format' => format_of(image), 'width' => rotated ? image.height : image.width,
      'height' => rotated ? image.width : image.height }
  end

  # Reads only the header until pixels are asked for
  def self.load(content, **)
    image = Vips::Image.new_from_file(content.path, **)
    format_of(image)
    image
  end

  def self.format_of(image)
    loader = image.get('vips-loader').to_s.delete_suffix('_source').delete_suffix('_buffer')
    LOADERS[loader] || raise(UnsupportedFormat, "libvips read #{loader}, which isn't allowed")
  end

  # rename: as ImageMagick's encode, and thumb given a format, give the content's name the new format's extension
  def self.write(content, image, format, quality: nil, rename: false)
    content.ext = format if rename
    format = 'jpeg' if format == 'jpg'
    suffix = SAVERS.fetch(format) { raise UnsupportedFormat, "can't write #{format}" }
    image = srgb(image)
    # No EXIF (a phone photo's GPS position among it), XMP or ICC profile: the pixels are sRGB now. keep (libvips 8.15,
    # which Render has) in place of strip, which it deprecates
    options = { keep: :none }
    if %w[jpeg webp heic].include?(format)
      options[:Q] = quality || DEFAULT_QUALITY
      # As ImageMagick does: about a fifth smaller, and the same pixels
      options[:optimize_coding] = true if format == 'jpeg'
      # Transparent pixels on white, rather than whatever colour they hide
      image = image.flatten(background: [255]) if format == 'jpeg' && image.has_alpha?
    end
    content.update(image.write_to_buffer(suffix, **options), 'format' => format)
  end

  # Colours from another profile (an iPhone's Display P3) converted to sRGB, as the profile is stripped. Left as they
  # are if the profile can't be read
  def self.srgb(image)
    return image unless image.get_typeof('icc-profile-data').positive?

    image.icc_transform('srgb')
  rescue Vips::Error
    image
  end

  def self.animated?(content)
    ANIMATED.include?(content.analyse(:format))
  end

  class Thumb
    include Dragonfly::ParamValidators

    def update_url(url_attributes, _geometry, opts = {})
      url_attributes.ext = opts['format'] if opts['format']
    end

    def call(content, geometry, opts = {})
      validate!(opts['format'], &is_word)
      raise ArgumentError, "thumb doesn't take #{(opts.keys - ['format']).join(', ')}" if (opts.keys - ['format']).any?

      width, height, options = thumbnail_args(geometry)
      # Every frame of an animation, stacked into one tall image
      frames = DragonflyVips.animated?(content) ? '[n=-1]' : ''
      image = Vips::Image.thumbnail("#{content.path}#{frames}", width, height:, **options)
      # The input's format, unless given another. Not the name's, as ImageMagick writes, which nothing relies on:
      # uploads ask for JPEG ('format' => 'jpeg')
      DragonflyVips.write(content, image, opts['format'] || DragonflyVips.format_of(image), rename: opts['format'].present?)
    end

    def thumbnail_args(geometry)
      case geometry
      when CROPPED_RESIZE_GEOMETRY
        [::Regexp.last_match(1).to_i, ::Regexp.last_match(2).to_i, { crop: :centre }]
      when RESIZE_GEOMETRY
        width, height, modifier = ::Regexp.last_match.captures
        raise ArgumentError, "Didn't recognise the geometry string #{geometry}" if width.empty? && height.empty?

        size = { '>' => :down, '<' => :up }.fetch(modifier, :both)
        [width.empty? ? UNBOUNDED : width.to_i, height.empty? ? UNBOUNDED : height.to_i, { size: }]
      else
        raise ArgumentError, "Didn't recognise the geometry string #{geometry}"
      end
    end
  end

  class Encode
    include Dragonfly::ParamValidators

    def update_url(url_attributes, format, _args = '')
      url_attributes.ext = format.to_s
    end

    def call(content, format, args = '')
      validate!(format, &is_word)
      quality = args.to_s.match(QUALITY) || raise(ArgumentError, "encode only takes -quality, not #{args}")
      quality = quality[1]&.to_i&.clamp(1, 100)

      format = format.to_s.downcase
      frames = DragonflyVips.animated?(content) && ANIMATED.include?(format) ? { n: -1 } : {}
      image = DragonflyVips.load(content, **frames)
      # As thumb does: the pixels turned as the EXIF orientation says, so the orientation isn't needed
      DragonflyVips.write(content, image.autorot, format, quality:, rename: true)
    end
  end
end
