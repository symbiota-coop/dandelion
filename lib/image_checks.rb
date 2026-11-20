# The checks /stats/images runs on the images libvips reads, draws and writes on this server, which CI can't vouch for:
# Render's libvips is Debian's, not the one CI or a laptop has, and a format it was built without (HEIC needs libheif,
# the avatar Pango and its font) only fails when someone uploads one. Each check works in memory on images made here
# (and a small HEIC, lib/image_checks/sample.heic), through Dragonfly.app as uploads and pages use it, storing nothing.
# The production checks read what's been stored lately: the thumbnails made, by format, and new events' images
module ImageChecks
  Check = Struct.new(:group, :name, :ok, :detail, :ms, keyword_init: true)

  # Block untrusted loaders (Vips.block_untrusted) needs 8.13; Render's Debian bookworm has 8.14
  MINIMUM_VERSION = Gem::Version.new('8.13')
  HEIC_SAMPLE = File.expand_path('image_checks/sample.heic', __dir__)
  FORMATS = { 'jpeg' => '.jpg', 'png' => '.png', 'gif' => '.gif', 'webp' => '.webp', 'heic' => '.heic' }.freeze
  SVG = '<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>'.freeze
  PDF = "%PDF-1.4\n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n2 0 obj << /Type /Pages /Kids [] /Count 0 >> endobj\ntrailer << /Root 1 0 R >>\n%%EOF\n".freeze
  # How far back the production checks look
  DEFAULT_HOURS = 24

  class << self
    def run(hours: DEFAULT_HOURS)
      loaded = check('libvips', 'Loaded') do
        # DragonflyVips::Plugin requires it as the app boots, so this only loads it on a server that isn't using it
        require 'vips'
        [true, Vips::LIBRARY_VERSION]
      rescue LoadError => e
        [false, "#{e.class}: #{e.message.truncate(200)}"]
      end
      return [loaded] unless loaded.ok

      [loaded] + library_checks + format_checks + upload_checks + derivative_checks + drawing_checks + production_checks(hours)
    end

    # The bytes of a width by height image in a format, a gradient so it has detail to encode; alpha: half of it clear
    def sample(format, width, height, alpha: false)
      return File.binread(HEIC_SAMPLE) if format == 'heic' && width.nil?

      xyz = Vips::Image.xyz(width, height)
      image = (xyz[0] * 255 / width).bandjoin([xyz[1] * 255 / height, (xyz[0] + xyz[1]) * 255 / (width + height)])
      image = image.bandjoin((xyz[0] < width / 2).ifthenelse(0, 255)) if alpha
      image.cast(:uchar).copy(interpretation: :srgb).write_to_buffer(FORMATS.fetch(format))
    end

    private

    def library_checks
      [check('libvips', 'Version') do
        [Gem::Version.new(Vips.version_string) >= MINIMUM_VERSION, "libvips #{Vips.version_string}, ruby-vips #{Vips::VERSION}"]
      end,
       check('libvips', 'Dragonfly runs on libvips') do
         processor = Dragonfly.app.get_processor(:thumb)
         [processor.is_a?(DragonflyVips::Thumb), processor.class.name]
       end]
    end

    # Each format read (as an upload or a stored original is) and written as a thumbnail (as an original in that format
    # gets its own); HEIC from a photo libheif made, so reading it is checked even if writing it fails
    def format_checks
      FORMATS.keys.map do |format|
        check('Formats', format.upcase) do
          job = Dragonfly.app.create(format == 'heic' ? sample('heic', nil, nil) : sample(format, 96, 64))
          read = [job.format, job.width, job.height]
          raise "read as #{read.join(' ')}" unless read[0] == format

          thumb = job.thumb('48x48').apply
          [thumb.format == format && [thumb.width, thumb.height] == [48, 32],
           "read #{read[1]}x#{read[2]}, thumbnail #{thumb.format} #{thumb.width}x#{thumb.height}"]
        end
      end
    end

    # What ImageWithValidation and Upload do with an upload: thumb('1920x1920>', 'format' => 'jpeg')
    def upload_checks
      [check('Uploads', 'PNG with transparency stored as a JPEG on white') do
        image = vips(Dragonfly.app.create(sample('png', 400, 300, alpha: true)).thumb('1920x1920>', 'format' => 'jpeg'))
        corner = image.getpoint(5, 5).map(&:round)
        [loader(image) == 'jpeg' && image.bands == 3 && corner.all? { |value| value > 245 }, "#{loader(image)}, clear corner now #{corner.inspect}"]
      end,
       check('Uploads', 'HEIC stored as a JPEG') do
         job = Dragonfly.app.create(sample('heic', nil, nil))
         raise "read as #{job.format}" unless job.format == 'heic'

         image = vips(job.thumb('1920x1920>', 'format' => 'jpeg'))
         [loader(image) == 'jpeg', "#{loader(image)} #{image.width}x#{image.height}"]
       end,
       check('Uploads', 'A 4000x3000 photo shrunk to 1920x1440') do
         image = vips(Dragonfly.app.create(sample('jpeg', 4000, 3000)).thumb('1920x1920>', 'format' => 'jpeg'))
         [[image.width, image.height] == [1920, 1440], "#{image.width}x#{image.height}"]
       end,
       check('Uploads', 'EXIF removed, and a turned photo stood upright') do
         photo = Vips::Image.new_from_buffer(sample('jpeg', 300, 200), '').copy
         photo.set_type(GObject::GINT_TYPE, 'orientation', 6)
         photo.set_type(GObject::GSTR_TYPE, 'exif-ifd0-Artist', 'Image checks')
         image = vips(Dragonfly.app.create(photo.write_to_buffer('.jpg')).thumb('1920x1920>', 'format' => 'jpeg'))
         exif = image.get_fields.grep(/\Aexif-/)
         [[image.width, image.height] == [200, 300] && exif.empty?, "#{image.width}x#{image.height}, #{exif.empty? ? 'no EXIF' : "EXIF: #{exif.first(3).join(', ')}"}"]
       end,
       check('Uploads', 'SVG and PDF refused') do
         images = { 'SVG' => SVG, 'PDF' => PDF }.select { |_, data| Dragonfly.app.create(data).image? }
         [images.empty?, images.empty? ? 'neither read as an image' : "read as images: #{images.keys.join(', ')}"]
       end]
    end

    # The derivatives pages ask for
    def derivative_checks
      photo = -> { Dragonfly.app.create(sample('jpeg', 1920, 1080)) }
      [check('Thumbnails', "thumb('400x400'), fitted") { size(photo.call.thumb('400x400'), [400, 225]) },
       check('Thumbnails', "thumb('500x500#'), cropped to fill") { size(photo.call.thumb('500x500#'), [500, 500]) },
       check('Thumbnails', 'Open Graph image') { size(photo.call.encode('jpg', '-quality 90').thumb('1200x630'), [1120, 630], 'jpeg') },
       check('Thumbnails', 'Animated GIF keeps its frames') do
         frames = [[255, 0, 0], [0, 0, 255]].map { |colour| Vips::Image.black(40, 30) + colour }
         gif = Vips::Image.arrayjoin(frames, across: 1).cast(:uchar).copy(interpretation: :srgb)
         gif.set_type(GObject::GINT_TYPE, 'page-height', 30)
         thumb = Vips::Image.new_from_buffer(Dragonfly.app.create(gif.write_to_buffer('.gif')).thumb('20x20').apply.data, '', n: -1)
         [thumb.get('n-pages') == 2, "#{thumb.get('n-pages')} frames of #{thumb.width}x#{thumb.get('page-height')}"]
       end]
    end

    # Pango, the font and the libvips text needs, which uploads don't use
    def drawing_checks
      [check('Drawing', 'Avatar initials') do
        raise "no font at #{AccountAvatar::FONT}" unless File.exist?(AccountAvatar::FONT)

        avatar = Vips::Image.new_from_buffer(Account.avatar_png('SR'), '')
        cut_out = avatar.extract_band(3).min.zero?
        [[avatar.width, avatar.height, avatar.bands] == [400, 400, 4] && cut_out,
         "#{avatar.width}x#{avatar.height}, letters #{cut_out ? 'cut out' : 'missing'}"]
      end]
    end

    # What's been stored lately: a stored file's uid starts with when it was stored (UTC), so the indexed uid finds them
    def production_checks(hours)
      since = hours.hours.ago.utc
      thumbnails = DragonflyJob.and(:uid.gte => since.strftime('%Y/%m/%d/%H/%M/%S')).limit(10_000).pluck(:uid)
      images = Event.and(:created_at.gte => since, :image_uid.ne => nil).limit(10_000).pluck(:image_uid)
      [check('Production', "Thumbnails stored in the last #{hours} hours") do
        [thumbnails.any?, thumbnails.any? ? by_format(thumbnails) : 'none: no page asked for a new one, or none could be made']
      end,
       check('Production', "New events' images in the last #{hours} hours are JPEGs") do
         others = images.reject { |uid| uid.downcase.end_with?('.jpeg', '.jpg') }
         [others.empty?, images.any? ? by_format(images) : 'no new events with images']
       end]
    end

    def by_format(uids)
      uids.group_by { |uid| File.extname(uid).delete('.').downcase.then { |format| format.empty? ? 'none' : format } }
          .sort_by { |_, group| -group.size }.map { |format, group| "#{group.size} #{format}" }.join(', ')
    end

    def size(job, expected, format = nil)
      image = vips(job)
      [[image.width, image.height] == expected && (format.nil? || loader(image) == format), "#{loader(image)} #{image.width}x#{image.height}"]
    end

    def vips(job)
      Vips::Image.new_from_buffer(job.apply.data, '')
    end

    def loader(image)
      image.get('vips-loader').delete_suffix('_buffer').delete_suffix('load')
    end

    def check(group, name)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ok, detail = begin
        yield
      rescue StandardError => e
        [false, "#{e.class}: #{e.message.truncate(200)}"]
      end
      Check.new(group: group, name: name, ok: ok, detail: detail, ms: ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round)
    end
  end
end
