require_relative '../test_config'
require_relative '../helpers/calendar_import_helpers'

# What imports take from Luma: which links count as its event pages, the cover image and theme colour from them, and
# the city label for venues it hides until people register
class OrganisationsCalendarImportLumaTest < ActiveSupport::TestCase
  include CalendarImportHelpers

  OG_IMAGE_URL = 'https://og.luma.com/cover.jpg?width=800,height=420'.freeze
  OG_IMAGE_URL_LARGE = 'https://og.luma.com/cover.jpg?width=1200,height=630'.freeze
  IMAGE_PATH = File.expand_path('../../app/assets/images/test-event.jpg', __dir__).freeze

  def luma_page(*og_images)
    "<html><head>#{og_images.map { |url| %(<meta property="og:image" content="#{url}">) }.join}</head></html>"
  end

  def luma_event(**overrides)
    vevent(uid: 'evt-abc@events.lu.ma', dtstart: '20270501T180000Z', dtend: '20270501T200000Z', summary: 'Luma evening',
           location: 'Kreuzberg, Berlin', **overrides)
  end

  # Serves Luma's image CDN from the app's test image, recording each image URL fetched
  def stub_luma_images(fetched_images = [], &)
    Dragonfly.app.stub(:fetch_url, lambda { |url, *|
      fetched_images << url.to_s
      Dragonfly.app.fetch_file(IMAGE_PATH)
    }, &)
  end

  # A MiniMagick image whose top-left pixel is the given colour, recording whether it was cleaned up
  def fake_minimagick_image(rgb, destroyed)
    image = Object.new
    image.define_singleton_method(:crop) { |_geometry| self }
    image.define_singleton_method(:get_pixels) { |_map| [[rgb]] }
    image.define_singleton_method(:tempfile) { true }
    image.define_singleton_method(:destroy!) { destroyed << true }
    image
  end

  # ── Which links are Luma event pages ──────────────────────────────────────

  test "a link to a Luma event page in a feed's LOCATION becomes the event's RSVP link, and other Luma links don't" do
    covers 'organisations/ical-feed-url-as-rsvp@35ecc6'
    event_pages = %w[
      https://luma.com/2j1ninpb
      https://www.luma.com/event/evt-abc
      https://luma.com/u/someone/event/evt-abc
      https://lu.ma/community/anything
      http://lu.ma/short
    ]
    not_event_pages = %w[
      https://luma.com/
      https://luma.com/user/someone
      https://luma.com/under_score
      https://luma.com.example.com/2j1ninpb
      https://notluma.com/2j1ninpb
    ]
    urls = event_pages + not_event_pages
    create_organisation(calendar_import_urls: FEED_URL)
    vevents = urls.each_with_index.map { |url, i| vevent(uid: "luma-link-#{i}", dtstart: (Time.utc(2027, 5, 1) + i.days).strftime('%Y%m%dT%H%M%SZ'), summary: "Event #{i}", location: url) }
    requested_urls = []

    stub_faraday({ FEED_URL => { status: 200, body: ical(*vevents) }, **event_pages.to_h { |url| [url, { status: 200, body: luma_page }] } },
                 requested_urls: requested_urls) do
      @organisation.sync_calendar_imports
    end

    urls.each_with_index do |url, i|
      event = @organisation.events.find_by(calendar_import_uid: "luma-link-#{i}")
      if event_pages.include?(url)
        assert_equal url, event.purchase_url, url
        assert_includes requested_urls, url, "#{url} is fetched for its cover image"
      else
        assert_nil event.purchase_url, url
        refute_includes requested_urls, url
      end
    end
  end

  # ── Cover images and theme colours ────────────────────────────────────────

  test "a Luma event's cover image is fetched from Luma's image host, larger, and its theme colour taken from its top-left pixel" do
    create_organisation(calendar_import_urls: LUMA_FEED_URL)
    fetched_images = []
    destroyed = []
    page_url = 'https://luma.com/event/evt-abc'
    requested_urls = []
    responses = { LUMA_FEED_URL => { status: 200, body: ical(luma_event) },
                  # A malformed og:image is passed over, as is one off Luma's image host
                  page_url => { status: 200, body: luma_page('https://og.luma.com/a cover.jpg', 'https://example.com/cover.jpg', OG_IMAGE_URL) } }

    MiniMagick::Image.stub(:open, ->(_path) { fake_minimagick_image([26, 43, 60], destroyed) }) do
      stub_luma_images(fetched_images) do
        stub_faraday(responses, requested_urls: requested_urls) { @organisation.sync_calendar_imports }
      end
    end

    event = @organisation.events.find_by(calendar_import_uid: 'evt-abc@events.lu.ma')
    assert_equal [OG_IMAGE_URL_LARGE], fetched_images
    assert event.image.present?
    assert_equal '#1A2B3C', event.theme_color
    assert_equal [true], destroyed, "MiniMagick's copy of the image is removed"

    # Once it has an image, later syncs don't fetch the page or recolour the event
    requested_urls.clear
    stub_faraday(responses, requested_urls: requested_urls) { @organisation.sync_calendar_imports }
    assert_equal [LUMA_FEED_URL], requested_urls
    assert_equal '#1A2B3C', event.reload.theme_color
  end

  test "an event whose Luma image the organisation's image rules refuse is imported without it" do
    create_organisation(calendar_import_urls: LUMA_FEED_URL, event_image_required_width: 500)
    fetched_images = []

    result = MiniMagick::Image.stub(:open, ->(_path) { fake_minimagick_image([26, 43, 60], []) }) do
      stub_luma_images(fetched_images) do
        stub_faraday(LUMA_FEED_URL => { status: 200, body: ical(luma_event) },
                     'https://luma.com/event/evt-abc' => { status: 200, body: luma_page(OG_IMAGE_URL) }) do
          @organisation.sync_calendar_imports
        end
      end
    end

    assert_equal [OG_IMAGE_URL_LARGE], fetched_images
    assert_equal 1, result[:created]
    assert_empty result[:errors]
    event = @organisation.events.find_by(calendar_import_uid: 'evt-abc@events.lu.ma')
    assert_equal 'Luma evening', event.name
    assert event.image.blank?
    assert_nil event.theme_color, "the refused image's colour isn't kept either"
  end

  # ── Venues Luma hides ─────────────────────────────────────────────────────

  test "a gated Luma venue whose city can't be found is labelled In person, keeping its coordinates" do
    covers 'organisations/ical-gated-venue-in-person@33de0a'
    create_organisation(calendar_import_urls: LUMA_FEED_URL)
    gated = ->(uid, geo) { luma_event(uid: uid, summary: uid, url: "https://luma.com/event/#{uid}", location: "https://luma.com/event/#{uid}", geo: geo) }
    feed = ical(gated.call('evt-nocity', '48.8566;2.3522'), gated.call('evt-failing', '40.4168;-3.7038'))
    pages = { 'https://luma.com/event/evt-nocity' => { status: 200, body: luma_page }, 'https://luma.com/event/evt-failing' => { status: 200, body: luma_page } }
    Geocoder::Lookup::Test.add_stub([48.8566, 2.3522], [{ 'city' => '' }])
    search = Geocoder.method(:search)

    Geocoder.stub(:search, ->(query, *args) { query == [40.4168, -3.7038] ? raise(Geocoder::ServiceUnavailable, 'down') : search.call(query, *args) }) do
      stub_faraday(LUMA_FEED_URL => { status: 200, body: feed }, **pages) { @organisation.sync_calendar_imports }
    end

    no_city = @organisation.events.find_by(calendar_import_uid: 'evt-nocity')
    assert_equal 'In person', no_city.location
    assert_equal [2.3522, 48.8566], no_city.coordinates
    failing = @organisation.events.find_by(calendar_import_uid: 'evt-failing')
    assert_equal 'In person', failing.location, 'a geocoder that fails gives In person'
    assert_equal [-3.7038, 40.4168], failing.coordinates
  ensure
    Geocoder::Lookup::Test.delete_stub([48.8566, 2.3522])
  end
end
