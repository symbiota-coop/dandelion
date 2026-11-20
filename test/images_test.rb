require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# Which uploaded files reach libvips, which Dragonfly runs: only JPEG, PNG, GIF, WebP and HEIC, known by their first
# bytes, and libvips refusing any other format
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

  test 'image fields refuse SVG, PostScript and other files, whatever their name, before libvips sees them' do
    create_organisation
    { SVG => '.svg', POSTSCRIPT => '.jpg', 'hello' => '.png' }.each do |data, ext|
      with_file(data, ext) do |file|
        organisation = Organisation.find(@organisation.id)
        without_libvips { organisation.image = file }

        refute organisation.valid?
        assert_includes organisation.errors[:image], 'must be a JPEG, PNG, GIF, WebP or HEIC image'
        assert_nil organisation.image
      end
    end
  end

  test 'image fields refuse an image too big to decode, from what its header says' do
    create_organisation
    { [4_000, 2] => true, [40_000, 2] => false }.each do |(width, height), allowed|
      with_file(Vips::Image.black(width, height).cast(:uchar).write_to_buffer('.png'), '.png') do |file|
        organisation = Organisation.find(@organisation.id)
        organisation.image = file

        assert_equal allowed, organisation.valid?, "#{width}x#{height}: #{organisation.errors.full_messages.to_sentence}"
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

  test 'image fields store a JPEG named .png or .heic as a JPEG, not in the format its name says' do
    create_organisation
    %w[.png .heic].each do |ext|
      with_file(File.binread('app/assets/images/test-event.jpg'), ext) do |file|
        organisation = Organisation.find(@organisation.id)
        organisation.image = file

        assert organisation.save, organisation.errors.full_messages.to_sentence
        organisation.reload
        assert_equal 'jpeg', organisation.image.format
        assert organisation.image_uid.end_with?('.jpeg'), organisation.image_uid
      end
    end
  end

  test 'uploads store images as JPEGs, including a JPEG named .png' do
    account = FactoryBot.create(:account)
    { 'coop.png' => '.png', 'test-event.jpg' => '.png' }.each do |name, ext|
      with_file(File.binread("app/assets/images/#{name}"), ext) do |file|
        upload = Upload.new(account: account, file: file)

        assert upload.save, upload.errors.full_messages.to_sentence
        upload.reload
        assert_equal 'jpeg', upload.file.format
        assert upload.file_uid.end_with?('.jpeg'), upload.file_uid
      end
    end
  end

  test 'uploads keep files that are not images as they are, and refuse SVGs' do
    account = FactoryBot.create(:account)
    with_file(SVG, '.txt') do |file|
      upload = Upload.new(account: account)
      without_libvips { upload.file = file }

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

  test 'Dragonfly, on libvips, refuses SVG and PostScript, even past ImageSignature' do
    [SVG, POSTSCRIPT].each do |data|
      job = Dragonfly.app.create(data)
      assert_equal false, job.image?
      assert_raises(Vips::Error, DragonflyVips::UnsupportedFormat) { job.analyse(:format) }
    end
    assert_equal 'png', Dragonfly.app.create(File.binread('app/assets/images/coop.png')).analyse(:format)
  end

end
