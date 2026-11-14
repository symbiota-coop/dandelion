require_relative '../test_config'

# Which image an event's page and calendar image show: its cohost's, its own, or its organisation's
class EventImagesTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # Stored directly, as an earlier upload would have left it, so the test doesn't need ImageMagick
  def store_image(record)
    record.set(image_uid: Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg')), image_width_unmagic: 1920, image_height_unmagic: 1080)
    # A fresh copy: the one in hand has already read its image as nil
    record.class.find(record.id)
  end

  def og_image
    last_response.body[/<meta property="og:image" content="([^"]*)"/, 1]
  end

  # Where the calendar image redirects to, less the host Rack adds
  def redirected_image
    assert last_response.redirect?, "Expected a redirect, got #{last_response.status}"
    URI(last_response.location).request_uri
  end

  def og_image_for(record)
    record.image.encode('jpg', '-quality 90').thumb('1200x630').url
  end

  test "an event without an image shares its organisation's, and has no calendar image" do
    covers_route 'GET /e/:slug'
    create_event
    organisation = store_image(@organisation)

    get "/e/#{@event.slug}"
    assert_equal 200, last_response.status
    assert_equal og_image_for(organisation), og_image

    get "/e/#{@event.slug}.jpg"
    assert_equal 404, last_response.status
  end

  test 'an event with an image shares its own, and its calendar image is it' do
    create_event
    organisation = store_image(@organisation)
    event = store_image(@event)

    get "/e/#{@event.slug}"
    assert_equal og_image_for(event), og_image
    refute_equal og_image_for(organisation), og_image

    get "/e/#{@event.slug}.jpg"
    assert_equal og_image_for(event), redirected_image
  end

  test "an event seen through a cohost shows the cohost's image" do
    create_event
    event = store_image(@event)
    cohost = FactoryBot.create(:organisation)
    cohostship = store_image(@event.cohostships.create!(organisation: cohost))

    get "/e/#{@event.slug}", cohost: cohost.slug
    assert_equal og_image_for(cohostship), og_image
    get "/e/#{@event.slug}.jpg", cohost: cohost.slug
    assert_equal og_image_for(cohostship), redirected_image

    get "/e/#{@event.slug}.jpg"
    assert_equal og_image_for(event), redirected_image
  end

  test 'an event with no image and an organisation with none has neither' do
    create_event

    get "/e/#{@event.slug}"
    assert_equal 200, last_response.status
    assert_equal "#{ENV['BASE_URI']}/images/link.png", og_image
    get "/e/#{@event.slug}.jpg"
    assert_equal 404, last_response.status
  end
end
