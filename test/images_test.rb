require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# Which uploaded files reach ImageMagick: only JPEG, PNG, GIF, WebP and HEIC, known by their first bytes, and the
# ImageMagick policy (config/imagemagick/policy.xml) refusing the formats that read files, fetch URLs or run Ghostscript
class ImagesTest < ActiveSupport::TestCase
  SVG = '<?xml version="1.0"?><svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><rect width="10" height="10"/></svg>'.freeze
  POSTSCRIPT = "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 10 10\nshowpage\n".freeze

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

  test 'image fields still take JPEGs and PNGs, stored as JPEGs' do
    create_organisation
    %w[test-event.jpg coop.png].each do |name|
      organisation = Organisation.find(@organisation.id)
      organisation.image = File.new("app/assets/images/#{name}")

      assert organisation.save, organisation.errors.full_messages.to_sentence
      assert_equal 'jpeg', organisation.reload.image.format
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
    [SVG, POSTSCRIPT].each do |data|
      assert_raises(Dragonfly::Shell::CommandFailed) { Dragonfly.app.create(data).analyse(:format) }
    end
    assert_equal 'png', Dragonfly.app.create(File.binread('app/assets/images/coop.png')).analyse(:format)
  end
end
