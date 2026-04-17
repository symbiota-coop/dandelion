require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class CalendarImportsTest < ActiveSupport::TestCase
  include Capybara::DSL

  ICS_URL_1 = 'https://calendar-one.example.com/events.ics'.freeze
  ICS_URL_2 = 'https://calendar-two.example.com/events.ics'.freeze
  WEBCAL_URL_2 = 'webcal://calendar-two.example.com/events.ics'.freeze

  TEST_ICAL_1 = <<~ICAL.freeze
    BEGIN:VCALENDAR
    VERSION:2.0
    X-WR-CALNAME:Calendar Alpha
    BEGIN:VEVENT
    UID:ical-event-1
    DTSTART:20270501T180000Z
    DTEND:20270501T200000Z
    SUMMARY:Imported iCal Event
    DESCRIPTION:Come along and bring a friend.
    LOCATION:Online
    URL:https://events.example.com/imported-ical-event
    END:VEVENT
    END:VCALENDAR
  ICAL

  TEST_ICAL_2 = <<~ICAL.freeze
    BEGIN:VCALENDAR
    VERSION:2.0
    X-WR-CALNAME:Calendar Beta
    BEGIN:VEVENT
    UID:ical-event-1
    DTSTART:20270503T180000Z
    DTEND:20270503T200000Z
    SUMMARY:Imported iCal Event From Feed Two
    DESCRIPTION:A different feed with the same UID.
    LOCATION:Berlin, Germany
    URL:https://events.example.com/imported-ical-event-two
    END:VEVENT
    END:VCALENDAR
  ICAL

  LUMA_ICS_URL = 'https://api2.luma.com/ics/get?entity=calendar&id=cal-test'.freeze
  LUMA_OG_IMAGE_URL = 'https://placehold.co/1200x630.jpg'.freeze
  LUMA_OG_IMAGE_FIXTURE_PATH = File.expand_path('../app/assets/images/test-event.jpg', __dir__).freeze

  LUMA_ICAL_LOCATION_ONLY = <<~ICAL.freeze
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:evt-test@events.lu.ma
    DTSTART:20270501T180000Z
    DTEND:20270501T200000Z
    SUMMARY:Luma Event
    LOCATION:https://luma.com/event/evt-test
    END:VEVENT
    END:VCALENDAR
  ICAL

  UPDATED_TEST_ICAL_1 = <<~ICAL.freeze
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:ical-event-1
    DTSTART:20270501T193000Z
    DTEND:20270501T213000Z
    SUMMARY:Imported iCal Event Updated
    DESCRIPTION:Updated details from the feed.
    LOCATION:Stockholm, Sweden
    URL:https://events.example.com/imported-ical-event
    END:VEVENT
    END:VCALENDAR
  ICAL

  CANCELLED_TEST_ICAL_1 = <<~ICAL.freeze
    BEGIN:VCALENDAR
    VERSION:2.0
    BEGIN:VEVENT
    UID:ical-event-1
    DTSTART:20270501T180000Z
    DTEND:20270501T200000Z
    SUMMARY:Imported iCal Event
    STATUS:CANCELLED
    URL:https://events.example.com/imported-ical-event
    END:VEVENT
    END:VCALENDAR
  ICAL

  def stub_faraday(responses)
    responder = lambda do |url, *_args|
      url = url.to_s
      response = responses.fetch(url) { raise "Unexpected Faraday.get for #{url}" }
      Struct.new(:status, :body, :headers) do
        def success?
          status.between?(200, 299)
        end
      end.new(response[:status], response[:body], response[:headers] || {})
    end

    connection_builder = lambda do |*args, **kwargs, &block|
      Faraday::Connection.new(*args, **kwargs) do |f|
        block&.call(f)
        f.adapter :test do |stub|
          responses.each do |url, spec|
            stub.get(url) { [spec[:status], spec[:headers] || {}, spec[:body]] }
          end
        end
      end
    end

    Faraday.stub(:get, responder) do
      Faraday.stub(:new, connection_builder) { yield }
    end
  end

  def stub_dragonfly_fetch_url(responses, fetched_urls: nil)
    fetcher = lambda do |url, *_args, **_kwargs, &_block|
      fetched_urls&.push(url.to_s)
      path = responses.fetch(url.to_s) { raise "Unexpected Dragonfly fetch_url for #{url}" }
      Dragonfly.app.fetch_file(path)
    end

    Dragonfly.app.stub(:fetch_url, fetcher) { yield }
  end

  test 'syncing multiple iCal feeds creates events from each feed' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, calendar_import_urls: "#{ICS_URL_1}\n#{WEBCAL_URL_2}")

    stub_faraday(
      ICS_URL_1 => { status: 200, body: TEST_ICAL_1 },
      ICS_URL_2 => { status: 200, body: TEST_ICAL_2 }
    ) do
      result = organisation.sync_calendar_imports

      assert_equal 2, result[:created]
      assert_equal 0, result[:updated]
      assert_equal 2, result[:feeds].count
      assert_empty result[:errors]
    end

    event_one = organisation.events.find_by(calendar_import_feed_url: ICS_URL_1)
    event_two = organisation.events.find_by(calendar_import_feed_url: ICS_URL_2)
    assert_equal 'Imported iCal Event', event_one.name
    assert_equal 'Imported iCal Event From Feed Two', event_two.name
    assert_equal 'https://events.example.com/imported-ical-event', event_one.calendar_import_source_url
    assert_equal 'https://events.example.com/imported-ical-event-two', event_two.calendar_import_source_url
    organisation.reload
    assert organisation.calendar_import_last_synced_at.present?
    assert_equal 'Calendar Alpha', organisation.calendar_import_feed_calendar_names[ICS_URL_1]
    assert_equal 'Calendar Beta', organisation.calendar_import_feed_calendar_names[ICS_URL_2]
  end

  test 'syncing multiple feeds keeps updates scoped to the correct feed' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, calendar_import_urls: "#{ICS_URL_1}\n#{ICS_URL_2}")

    stub_faraday(
      ICS_URL_1 => { status: 200, body: TEST_ICAL_1 },
      ICS_URL_2 => { status: 200, body: TEST_ICAL_2 }
    ) do
      organisation.sync_calendar_imports
    end

    event_one = organisation.events.find_by(calendar_import_feed_url: ICS_URL_1)
    event_two = organisation.events.find_by(calendar_import_feed_url: ICS_URL_2)
    event_one.update!(featured: true)

    stub_faraday(
      ICS_URL_1 => { status: 200, body: UPDATED_TEST_ICAL_1 },
      ICS_URL_2 => { status: 200, body: TEST_ICAL_2 }
    ) do
      result = organisation.sync_calendar_imports

      assert_equal 0, result[:created]
      assert_equal 1, result[:updated]
      assert_empty result[:errors]
    end

    event_one.reload
    event_two.reload
    assert_equal 'Imported iCal Event Updated', event_one.name
    assert_equal 'Updated details from the feed.', event_one.description
    assert_equal 'Stockholm, Sweden', event_one.location
    assert_equal Time.utc(2027, 5, 1, 19, 30, 0), event_one.start_time.utc
    assert event_one.featured?, 'Dandelion-specific settings should be preserved'
    assert_equal 'Imported iCal Event From Feed Two', event_two.name
    assert_equal 'Berlin, Germany', event_two.location
  end

  test 'sync stores aggregated errors when one feed fails' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, calendar_import_urls: "#{ICS_URL_1}\n#{ICS_URL_2}")

    stub_faraday(
      ICS_URL_1 => { status: 200, body: TEST_ICAL_1 },
      ICS_URL_2 => { status: 404, body: '' }
    ) do
      result = organisation.sync_calendar_imports

      assert_equal 1, result[:created]
      assert_equal 1, result[:errors].count
      assert_equal "#{ICS_URL_2}: iCal feed returned 404", result[:errors].first
    end

    assert_equal "#{ICS_URL_2}: iCal feed returned 404", organisation.reload.calendar_import_last_sync_error
  end

  EMPTY_ICAL = <<~ICAL.freeze
    BEGIN:VCALENDAR
    VERSION:2.0
    END:VCALENDAR
  ICAL

  INVALID_ICAL_RESPONSE = '<html><body>Sign in first</body></html>'.freeze

  test 'syncing when an event drops out of the feed destroys the imported event' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, calendar_import_urls: ICS_URL_1)

    stub_faraday(ICS_URL_1 => { status: 200, body: TEST_ICAL_1 }) do
      organisation.sync_calendar_imports
    end

    event = organisation.events.find_by(calendar_import_feed_url: ICS_URL_1)
    assert event.present?

    stub_faraday(ICS_URL_1 => { status: 200, body: EMPTY_ICAL }) do
      result = organisation.sync_calendar_imports

      assert_equal 1, result[:removed]
      assert_empty result[:errors]
    end

    assert_nil Event.find(event.id)
    assert Event.unscoped.find(event.id).deleted_at.present?
  end

  test 'syncing when the feed returns a non-calendar 200 response keeps imported events' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, calendar_import_urls: ICS_URL_1)

    stub_faraday(ICS_URL_1 => { status: 200, body: TEST_ICAL_1 }) do
      organisation.sync_calendar_imports
    end

    event = organisation.events.find_by(calendar_import_feed_url: ICS_URL_1)
    assert event.present?

    stub_faraday(ICS_URL_1 => { status: 200, body: INVALID_ICAL_RESPONSE }) do
      result = organisation.sync_calendar_imports

      assert_equal 0, result[:removed]
      assert_equal ["#{ICS_URL_1}: iCal feed did not return a VCALENDAR payload"], result[:errors]
    end

    assert_equal event.id, organisation.events.find_by(calendar_import_feed_url: ICS_URL_1)&.id
    assert_nil Event.unscoped.find(event.id).deleted_at
  end

  test 'syncing a cancelled iCal event unpublishes the imported event' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, calendar_import_urls: ICS_URL_1)

    stub_faraday(ICS_URL_1 => { status: 200, body: TEST_ICAL_1 }) do
      organisation.sync_calendar_imports
    end

    event = organisation.events.find_by(calendar_import_feed_url: ICS_URL_1)

    stub_faraday(ICS_URL_1 => { status: 200, body: CANCELLED_TEST_ICAL_1 }) do
      result = organisation.sync_calendar_imports

      assert_equal 1, result[:updated]
      assert_empty result[:errors]
    end

    assert_nil Event.find(event.id)
    assert Event.unscoped.find(event.id).deleted_at.present?
  end

  test 'Luma iCal uses LOCATION as source URL and fetches og:image when URL property is absent' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, calendar_import_urls: LUMA_ICS_URL)
    luma_event_url = 'https://luma.com/event/evt-test'
    resolved_page_url = 'https://lu.ma/evt-test'
    fetched_urls = []
    # Wide image for validation; production Luma pages 307 to a short URL then serve og tags
    html = "<!DOCTYPE html><html><head><meta property=\"og:image\" content=\"#{LUMA_OG_IMAGE_URL}\"></head><body></body></html>"

    stub_dragonfly_fetch_url(
      { LUMA_OG_IMAGE_URL => LUMA_OG_IMAGE_FIXTURE_PATH },
      fetched_urls: fetched_urls
    ) do
      stub_faraday(
        LUMA_ICS_URL => { status: 200, body: LUMA_ICAL_LOCATION_ONLY },
        luma_event_url => { status: 307, body: '', headers: { 'location' => resolved_page_url } },
        resolved_page_url => { status: 200, body: html }
      ) do
        result = organisation.sync_calendar_imports

        assert_equal 1, result[:created]
        assert_empty result[:errors]
      end
    end

    event = organisation.events.find_by(calendar_import_feed_url: LUMA_ICS_URL)
    assert_equal luma_event_url, event.calendar_import_source_url
    assert_equal luma_event_url, event.purchase_url
    assert_equal 'Online', event.location
    assert_equal [LUMA_OG_IMAGE_URL], fetched_urls
  end

  test 'Luma iCal keeps plain-text LOCATION when not a URL' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, calendar_import_urls: LUMA_ICS_URL)
    ical = <<~ICAL
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:non-luma-uid@example.com
      DTSTART:20270501T180000Z
      DTEND:20270501T200000Z
      SUMMARY:In-person Luma Event
      LOCATION:The Fold, San Francisco, CA
      END:VEVENT
      END:VCALENDAR
    ICAL

    stub_faraday(LUMA_ICS_URL => { status: 200, body: ical }) do
      organisation.sync_calendar_imports
    end

    event = organisation.events.find_by(calendar_import_feed_url: LUMA_ICS_URL)
    assert_equal 'The Fold, San Francisco, CA', event.location
  end

  test 'Luma iCal derives purchase URL from evt- UID when URL and LOCATION lack a Luma link' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, calendar_import_urls: LUMA_ICS_URL)
    luma_event_url = 'https://luma.com/event/evt-inperson'
    fetched_urls = []
    html = "<!DOCTYPE html><html><head><meta property=\"og:image\" content=\"#{LUMA_OG_IMAGE_URL}\"></head><body></body></html>"
    ical = <<~ICAL
      BEGIN:VCALENDAR
      VERSION:2.0
      BEGIN:VEVENT
      UID:evt-inperson@events.lu.ma
      DTSTART:20270501T180000Z
      DTEND:20270501T200000Z
      SUMMARY:In-person Luma Event
      DESCRIPTION:No URL property; LOCATION is the venue only.
      LOCATION:CIC Berlin, Germany
      END:VEVENT
      END:VCALENDAR
    ICAL

    stub_dragonfly_fetch_url(
      { LUMA_OG_IMAGE_URL => LUMA_OG_IMAGE_FIXTURE_PATH },
      fetched_urls: fetched_urls
    ) do
      stub_faraday(
        LUMA_ICS_URL => { status: 200, body: ical },
        luma_event_url => { status: 307, body: '', headers: { 'location' => 'https://lu.ma/inperson' } },
        'https://lu.ma/inperson' => { status: 200, body: html }
      ) do
        result = organisation.sync_calendar_imports

        assert_equal 1, result[:created]
        assert_empty result[:errors]
      end
    end

    event = organisation.events.find_by(calendar_import_feed_url: LUMA_ICS_URL)
    assert_equal luma_event_url, event.calendar_import_source_url
    assert_equal luma_event_url, event.purchase_url
    assert_equal 'CIC Berlin, Germany', event.location
    assert_equal [LUMA_OG_IMAGE_URL], fetched_urls
  end
end
