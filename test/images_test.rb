require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# Which uploaded files reach ImageMagick: only JPEG, PNG, GIF, WebP and HEIC, known by their first bytes and read as
# that whatever they're named, and the ImageMagick policy (config/imagemagick/policy.xml) refusing every delegate
# program, the formats that read files or fetch URLs, and images too big to decode
class ImagesTest < ActiveSupport::TestCase
  SVG = '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>'.freeze
  POSTSCRIPT = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\nshowpage\n".freeze
  # The programs ImageMagick's delegates run (/etc/ImageMagick-6/delegates.xml) for the formats it has no coder for
  DELEGATE_PROGRAMS = %w[ffmpeg rsvg-convert dot hp2xx libreoffice soffice html2ps dwebp gs].freeze
  # The extensions of formats ImageMagick hands to those programs
  DELEGATE_EXTENSIONS = %w[mp4 svg dot hpgl docx html].freeze

  # The start of an ISO base media file of the given brand
  def ftyp(brand)
    "\x00\x00\x00\x18ftyp#{brand}\x00\x00\x00\x00mif1heic".b + ("\x00".b * 64)
  end

  # A PNG of one black row after another, as wide and tall as given, made without ImageMagick
  def png(width, height)
    chunk = ->(type, data) { [data.bytesize].pack('N') + type + data + [Zlib.crc32(type + data)].pack('N') }
    "\x89PNG\r\n\x1A\n".b + chunk.call('IHDR', [width, height, 8, 0, 0, 0, 0].pack('NNC5')) +
      chunk.call('IDAT', Zlib.deflate("\x00".b * (width + 1) * height)) + chunk.call('IEND', '')
  end

  # Puts stand-ins for the delegate programs first on the PATH ImageMagick inherits, and returns what any of them was
  # asked to do
  def recording_delegates
    Dir.mktmpdir do |dir|
      log = File.join(dir, 'ran.log')
      DELEGATE_PROGRAMS.each do |program|
        File.write(File.join(dir, program), "#!/bin/sh\necho #{program} \"$@\" >> #{log}\nexit 1\n")
        File.chmod(0o755, File.join(dir, program))
      end
      with_env('PATH' => "#{dir}:#{ENV.fetch('PATH')}") { yield }
      File.exist?(log) ? File.read(log) : ''
    end
  end

  # The ImageMagick commands Dragonfly runs in the block
  def imagemagick_commands
    commands = []
    shell = Dragonfly.app.shell
    run = shell.method(:run)
    record = lambda do |command, *args|
      commands << command
      run.call(command, *args)
    end
    shell.stub(:run, record) { yield }
    commands
  end

  def with_file(data, ext)
    Tempfile.create(['upload', ext], binmode: true) do |file|
      file.write(data)
      file.rewind
      yield file
    end
  end

  test 'image fields refuse SVG, PostScript and other files, whatever their name, before ImageMagick sees them' do
    create_organisation
    { SVG => '.svg', POSTSCRIPT => '.jpg', 'hello' => '.png' }.each do |data, ext|
      with_file(data, ext) do |file|
        organisation = Organisation.find(@organisation.id)
        without_imagemagick { organisation.image = file }

        refute organisation.valid?
        assert_includes organisation.errors[:image], 'must be a JPEG, PNG, GIF, WebP or HEIC image'
        assert_nil organisation.image
      end
    end
  end

  test 'image fields refuse HEIF sequences and layered images, whose bytes ImageMagick does not know, before ImageMagick sees them' do
    create_organisation
    %w[hevc hevx heim heis msf1 avis].each do |brand|
      with_file(ftyp(brand), '.mp4') do |file|
        organisation = Organisation.find(@organisation.id)
        without_imagemagick { organisation.image = file }

        refute organisation.valid?
        assert_includes organisation.errors[:image], 'must be a JPEG, PNG, GIF, WebP or HEIC image'
      end
    end
    assert_equal %w[heic heic heic avif], (%w[heic heix mif1 avif].map { |brand| ImageSignature.format(Dragonfly.app.create(ftyp(brand))) })
  end

  test 'ImageMagick hands no file to a delegate program under our policy, whatever it is named' do
    with_imagemagick do
      ran = recording_delegates do
        DELEGATE_EXTENSIONS.each do |ext|
          assert_raises(Dragonfly::Shell::CommandFailed) { Dragonfly.app.create(ftyp('hevc'), 'name' => "upload.#{ext}").analyse(:format) }
        end
      end
      assert_equal '', ran
    end
  end

  test 'image fields and uploads take JPEG, PNG, GIF, WebP and AVIF named as anything, read and stored as what their bytes are' do
    create_organisation
    account = FactoryBot.create(:account)
    with_imagemagick do
      jpeg = File.binread('app/assets/images/test-event.jpg')
      images = { jpeg => 'jpeg', File.binread('app/assets/images/coop.png') => 'png', Dragonfly.app.create(jpeg).encode('gif').data => 'gif',
                 File.binread('app/assets/images/paper-grain.webp') => 'webp', File.binread('test/fixtures/image.avif') => 'avif' }
      images.each do |data, format|
        assert_equal format, ImageSignature.format(Dragonfly.app.create(data))
        DELEGATE_EXTENSIONS.first(2).each do |ext|
          with_file(data, ".#{ext}") do |file|
            organisation = Organisation.find(@organisation.id)
            upload = Upload.new(account: account)
            commands = nil
            ran = recording_delegates do
              commands = imagemagick_commands do
                organisation.image = file
                assert organisation.save, "#{format} named .#{ext}: #{organisation.errors.full_messages.to_sentence}"
                upload.file = File.new(file.path)
                assert upload.save, "#{format} named .#{ext}: #{upload.errors.full_messages.to_sentence}"
              end
            end

            assert_equal '', ran
            assert_includes commands.join("\n"), ".#{format} "
            refute_includes commands.join("\n"), ".#{ext}"
            assert_equal 'jpeg', organisation.reload.image.format
            assert_operator organisation.image.width, :<=, 1920
            assert_equal 'jpeg', upload.reload.file.format
          end
        end
      end
    end
  end

  test 'ImageMagick refuses images wider or bigger than our policy allows' do
    create_organisation
    with_imagemagick do
      # The host may have a policy of its own (Ubuntu's allows more of each but the same width, and builds print the
      # width as 32KP or 32000P), so these show ours is the one that holds. Not every build lists the time limit in
      # force, so that's checked as one ImageMagick read from our file
      limits = Dragonfly.app.shell.run('identify -list resource').scan(/^\s*(\w[\w ]*): (\S+)$/).to_h
      assert_equal({ 'Area' => '128MP', 'Memory' => '256MiB', 'Map' => '512MiB', 'Disk' => '1GiB' }, limits.slice('Area', 'Memory', 'Map', 'Disk'))
      %w[Width Height].each do |name|
        number, unit = limits.fetch(name).match(/\A(\d+)(K?)P\z/).captures
        assert_operator number.to_i * (unit == 'K' ? 1024 : 1), :<=, 32 * 1024, "#{name}: #{limits[name]}"
      end
      ours = Dragonfly.app.shell.run('identify -list policy')[%r{^Path: \S*config/imagemagick/policy\.xml$.*?(?=^Path: |\z)}m]
      assert_match(/name: time\s+value: 120$/, ours.to_s)
      { 4_000 => true, 40_000 => false }.each do |width, allowed|
        with_file(png(width, 2), '.png') do |file|
          organisation = Organisation.find(@organisation.id)
          organisation.image = file

          assert_equal allowed, organisation.valid?, "#{width}px: #{organisation.errors.full_messages.to_sentence}"
        end
      end
    end
  end

  test 'image fields still take JPEGs and PNGs, stored as JPEGs' do
    create_organisation
    with_imagemagick do
      %w[test-event.jpg coop.png].each do |name|
        organisation = Organisation.find(@organisation.id)
        organisation.image = File.new("app/assets/images/#{name}")

        assert organisation.save, organisation.errors.full_messages.to_sentence
        assert_equal 'jpeg', organisation.reload.image.format
      end
    end
  end

  test 'uploads keep files that are not images as they are, and refuse SVGs' do
    account = FactoryBot.create(:account)
    with_file(SVG, '.txt') do |file|
      upload = Upload.new(account: account)
      without_imagemagick { upload.file = file }

      assert upload.save
      assert_equal SVG, upload.reload.file.data
      assert upload.file.name.end_with?('.txt')
    end
    with_file(SVG, '.svg') do |file|
      upload = Upload.new(account: account, file: file)

      refute upload.valid?
      assert_includes upload.errors[:file], 'type is not allowed'
    end
  end

  test 'ImageMagick refuses SVG and PostScript under our policy' do
    assert_includes ENV.fetch('MAGICK_CONFIGURE_PATH'), File.expand_path('../config/imagemagick', __dir__)
    with_imagemagick do
      [SVG, POSTSCRIPT].each do |data|
        assert_raises(Dragonfly::Shell::CommandFailed) { Dragonfly.app.create(data).analyse(:format) }
      end
      assert_equal 'png', Dragonfly.app.create(File.binread('app/assets/images/coop.png')).analyse(:format)
    end
  end
end
