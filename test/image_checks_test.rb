require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# /stats/images: libvips' checks on the server it runs on (ImageChecks), which pass here, as CI's libvips can do it all,
# and fail when what they check is wrong
class ImageChecksTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # A stored file's uid, as Dragonfly's datastore names it: when it was stored (UTC), then its own path
  def stored_uid(time, extension)
    "#{time.utc.strftime('%Y/%m/%d/%H/%M/%S')}/#{SecureRandom.uuid}/image.#{extension}"
  end

  def checks(hours: ImageChecks::DEFAULT_HOURS)
    ImageChecks.run(hours:).index_by(&:name)
  end

  test 'the images page checks libvips for admins, every check passing with thumbnails and JPEG event images stored lately' do
    covers_route 'GET /stats/images'
    DragonflyJob.create!(signature: SecureRandom.hex, uid: stored_uid(1.hour.ago, 'jpg'))
    create_event.set(image_uid: stored_uid(1.hour.ago, 'jpeg'))

    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    get '/stats/images'

    assert last_response.ok?, last_response.status.to_s
    %w[libvips Formats Uploads Thumbnails Drawing Production].each do |group|
      assert_includes last_response.body, "<th colspan=\"4\">#{group}</th>"
    end
    assert_includes last_response.body, '1 jpg'
    failed = ImageChecks.run.reject(&:ok)
    assert_empty failed, failed.map { |check| "#{check.name}: #{check.detail}" }.join("\n")
    assert_includes last_response.body, "#{ImageChecks.run.size} of #{ImageChecks.run.size} passed"

    sign_in_with_rack(FactoryBot.create(:account))
    get '/stats/images'
    assert last_response.redirect?
    assert_not_includes last_response.body, 'Thumbnails'
  end

  test 'the production checks fail with no thumbnails stored lately, or a new event image that is not a JPEG' do
    DragonflyJob.create!(signature: SecureRandom.hex, uid: stored_uid(3.days.ago, 'jpg'))
    create_event.set(image_uid: stored_uid(1.hour.ago, 'png'))

    day = checks
    assert_equal false, day['Thumbnails stored in the last 24 hours'].ok
    assert_equal false, day["New events' images in the last 24 hours are JPEGs"].ok
    assert_equal '1 png', day["New events' images in the last 24 hours are JPEGs"].detail

    # Over the week, the older thumbnail counts
    assert_equal true, checks(hours: 24 * 7)['Thumbnails stored in the last 168 hours'].ok
  end

  test 'the format and drawing checks fail when libvips gets them wrong' do
    Dragonfly.app.stub(:create, ->(*) { Dragonfly.app.fetch_file('app/assets/images/coop.png') }) do
      results = checks
      assert_equal false, results['HEIC'].ok
      assert_equal false, results['HEIC stored as a JPEG'].ok
      assert_equal false, results['SVG and PDF refused'].ok
      assert_equal false, results['AVIF stored as a JPEG'].ok
      assert_equal false, results['An image too big to decode refused from its header'].ok
    end

    opaque = (Vips::Image.black(400, 400, bands: 4) + 255).cast(:uchar).write_to_buffer('.png')
    Account.stub(:avatar_png, opaque) do
      assert_equal false, checks['Avatar initials'].ok
    end
  end

  test 'without libvips, the checks say so rather than fail one by one' do
    results = ImageChecks.stub(:require, ->(*) { raise LoadError, 'cannot load such file -- vips' }) { ImageChecks.run }

    assert_equal [['Loaded', false]], (results.map { |check| [check.name, check.ok] })
    assert_includes results.first.detail, 'cannot load such file -- vips'
  end

  test 'the HEIC sample is one an upload would be let through as' do
    attachment = Struct.new(:data) { def file = yield(StringIO.new(data)) }.new(File.binread(ImageChecks::HEIC_SAMPLE))
    assert_equal true, ImageSignature.allowed?(attachment)
    assert_equal 'heic', Dragonfly.app.create(attachment.data).format
  end
end
