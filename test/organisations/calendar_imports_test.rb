require_relative '../test_config'
require_relative '../helpers/calendar_import_helpers'

class OrganisationsCalendarImportsTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include Capybara::DSL
  include CalendarImportHelpers

  # ── Importing ─────────────────────────────────────────────────────────────

  test 'importing a feed creates its upcoming events for the organisation, with their times, places and descriptions' do
    covers 'organisations/ical-import-and-sync@e9f417', 'organisations/ical-feed-url-as-rsvp@35ecc6'
    create_organisation(calendar_import_urls: FEED_URL)
    feed = ical(
      meetup,
      vevent(uid: 'zoned-1', dtstart: ';TZID=Europe/London:20270601T190000', dtend: ';TZID=Europe/London:20270601T210000', summary: 'Zoned talk'),
      vevent(uid: 'all-day-1', dtstart: ';VALUE=DATE:20270610', dtend: ';VALUE=DATE:20270611', summary: 'Festival day'),
      vevent(uid: 'no-end-1', dtstart: '20270615T100000Z', summary: 'Open-ended walk'),
      vevent(uid: 'backwards-1', dtstart: '20270616T100000Z', dtend: '20270616T090000Z', summary: 'Ends before it starts'),
      vevent(uid: 'past-1', dtstart: '20200101T100000Z', dtend: '20200101T110000Z', summary: 'Long gone'),
      vevent(uid: 'untitled-1', dtstart: '20270620T100000Z'),
      vevent(uid: 'no-start-1', summary: 'No start'),
      vevent(uid: 'cancelled-1', dtstart: '20270621T100000Z', summary: 'Called off', status: 'CANCELLED')
    )

    result = import(@organisation, feed)

    assert_equal 5, result[:created]
    assert_equal 4, result[:skipped]
    assert_empty result[:errors]
    events = @organisation.events.and(calendar_import_feed_url: FEED_URL)
    assert_equal ['Ends before it starts', 'Festival day', 'Monthly meetup', 'Open-ended walk', 'Zoned talk'], events.pluck(:name).sort

    meetup_event = events.find_by(name: 'Monthly meetup')
    assert_equal @organisation, meetup_event.organisation
    assert_equal @organisation.account, meetup_event.account
    assert_equal Time.utc(2027, 5, 1, 18), meetup_event.start_time.utc
    assert_equal Time.utc(2027, 5, 1, 20), meetup_event.end_time.utc
    assert_equal 'Hackney, London', meetup_event.location
    assert_equal 'Bring a friend.', meetup_event.description
    assert_equal 'meetup-1', meetup_event.calendar_import_uid
    assert_equal 'https://events.example.com/meetup', meetup_event.purchase_url

    zoned = events.find_by(name: 'Zoned talk')
    assert_equal Time.utc(2027, 6, 1, 18), zoned.start_time.utc, '19:00 in London in June is 18:00 UTC'
    assert_equal Time.utc(2027, 6, 1, 20), zoned.end_time.utc
    assert_equal 'Online', zoned.location, 'an event without a location is online'
    assert_nil zoned.purchase_url

    # All-day dates are midnights in the organisation's time zone (or the default)
    all_day = events.find_by(name: 'Festival day')
    stockholm = Time.find_zone!(ENV['DEFAULT_TIME_ZONE'])
    assert_equal stockholm.local(2027, 6, 10), all_day.start_time
    assert_equal stockholm.local(2027, 6, 11), all_day.end_time

    no_end = events.find_by(name: 'Open-ended walk')
    assert_equal Time.utc(2027, 6, 15, 11), no_end.end_time.utc, 'an event without an end lasts an hour'
    backwards = events.find_by(name: 'Ends before it starts')
    assert_equal Time.utc(2027, 6, 16, 11), backwards.end_time.utc, 'an end before the start is taken as an hour after it'
  end

  test "all-day events start at midnight in the organisation's own time zone" do
    create_organisation(calendar_import_urls: FEED_URL, time_zone: 'America/New_York')

    import(@organisation, ical(vevent(uid: 'all-day-1', dtstart: ';VALUE=DATE:20270610', dtend: ';VALUE=DATE:20270611', summary: 'Festival day')))

    event = @organisation.events.find_by(calendar_import_uid: 'all-day-1')
    assert_equal Time.utc(2027, 6, 10, 4), event.start_time.utc
  end

  test 'a recurring event is imported once, at the start its feed gives' do
    create_organisation(calendar_import_urls: FEED_URL)

    result = import(@organisation, ical(meetup(rrule: 'FREQ=WEEKLY;COUNT=4')))

    assert_equal 1, result[:created]
    assert_equal [Time.utc(2027, 5, 1, 18)], @organisation.events.pluck(:start_time).map(&:utc)
  end

  test "the first import doesn't post notifications, but events added to the feed later do" do
    create_organisation(calendar_import_urls: FEED_URL)

    import(@organisation, ical(meetup))
    assert_empty @organisation.events.first.notifications

    import(@organisation, ical(meetup, vevent(uid: 'later-1', dtstart: '20270601T180000Z', summary: 'Added later')))
    assert_equal ['created_event'], @organisation.events.find_by(calendar_import_uid: 'later-1').notifications.pluck(:type)
  end

  # ── Syncing again ─────────────────────────────────────────────────────────

  test "syncing an unchanged feed again doesn't duplicate or resave its events" do
    covers 'organisations/ical-import-and-sync@e9f417'
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup))
    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')
    synced_at = event.calendar_import_last_synced_at

    result = import(@organisation, ical(meetup))

    assert_equal({ created: 0, updated: 0, skipped: 1, removed: 0 }, result.slice(:created, :updated, :skipped, :removed))
    assert_equal [event.id], @organisation.events.pluck(:id)
    assert_equal synced_at, event.reload.calendar_import_last_synced_at
  end

  test 'events without a UID are matched again by their URL, or else by their title and start' do
    create_organisation(calendar_import_urls: FEED_URL)
    with_url = vevent(dtstart: '20270501T180000Z', summary: 'Has a URL', url: 'https://events.example.com/has-url')
    bare = vevent(dtstart: '20270502T180000Z', summary: 'Bare event')
    import(@organisation, ical(with_url, bare))
    ids = @organisation.events.pluck(:id).sort

    renamed = vevent(dtstart: '20270501T180000Z', summary: 'Has a URL, renamed', url: 'https://events.example.com/has-url')
    result = import(@organisation, ical(renamed, bare))

    assert_equal 0, result[:created]
    assert_equal 0, result[:removed]
    assert_equal ids, @organisation.events.pluck(:id).sort
    assert @organisation.events.find_by(name: 'Has a URL, renamed')
  end

  test "an imported event's details follow the feed, overwriting edits made on Dandelion, but its other settings are kept" do
    covers 'organisations/ical-import-and-sync@e9f417'
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup))
    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')
    event.update!(name: 'Edited on Dandelion', location: 'Somewhere else', capacity: 30, featured: true)

    result = import(@organisation, ical(meetup))

    assert_equal 1, result[:updated]
    event.reload
    assert_equal 'Monthly meetup', event.name
    assert_equal 'Hackney, London', event.location
    assert_equal 30, event.capacity
    assert event.featured?
  end

  test "syncing removes the feed's events that have left it, but no other events" do
    covers 'organisations/ical-import-and-sync@e9f417'
    create_organisation(calendar_import_urls: "#{FEED_URL}\n#{OTHER_FEED_URL}")
    second = vevent(uid: 'meetup-2', dtstart: '20270601T180000Z', summary: 'June meetup')
    stub_faraday(FEED_URL => { status: 200, body: ical(meetup, second) },
                 OTHER_FEED_URL => { status: 200, body: ical(meetup(summary: 'Other meetup')) }) do
      @organisation.sync_calendar_imports
    end
    create_event(as: :hand_made, organisation: @organisation, name: 'Made on Dandelion')
    june = @organisation.events.find_by(calendar_import_feed_url: FEED_URL, calendar_import_uid: 'meetup-2')

    result = nil
    stub_faraday(FEED_URL => { status: 200, body: ical(meetup) },
                 OTHER_FEED_URL => { status: 200, body: ical(meetup(summary: 'Other meetup')) }) do
      result = @organisation.sync_calendar_imports
    end

    assert_equal 1, result[:removed]
    assert_nil Event.find(june.id)
    assert Event.unscoped.find(june.id).deleted_at
    assert Event.find(@hand_made.id)
    assert_equal 2, @organisation.events.and(calendar_import_uid: 'meetup-1').count, 'the same UID in another feed is a separate event'
  end

  test 'an imported event that has passed stays when the feed still lists it' do
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup))
    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')

    travel_to Time.utc(2027, 5, 10) do
      result = import(@organisation, ical(meetup))

      assert_equal 0, result[:removed]
      assert_equal 1, result[:skipped]
    end
    assert Event.find(event.id)
  end

  test "an event cancelled in the feed is removed, and one never imported isn't created" do
    covers 'organisations/ical-import-and-sync@e9f417'
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup))
    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')

    result = import(@organisation, ical(meetup(status: 'CANCELLED'), vevent(uid: 'new-1', dtstart: '20270601T180000Z', summary: 'New but off', status: 'CANCELLED')))

    assert_equal 1, result[:updated]
    assert_equal 1, result[:skipped]
    assert_nil Event.find(event.id)
    assert_equal 0, @organisation.events.count
  end

  # ── Bad feeds ─────────────────────────────────────────────────────────────

  test "a feed that errors, times out or can't be reached is reported, keeping its events, while other feeds still sync" do
    create_organisation(calendar_import_urls: "#{FEED_URL}\n#{OTHER_FEED_URL}")
    import(@organisation, ical(meetup))
    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')

    [
      [{ status: 500, body: 'Oops' }, 'iCal feed returned 500'],
      [Faraday::TimeoutError.new('execution expired'), 'execution expired'],
      [Faraday::ConnectionFailed.new('Failed to open TCP connection'), 'Failed to open TCP connection']
    ].each do |response, message|
      result = nil
      stub_faraday(FEED_URL => response, OTHER_FEED_URL => { status: 200, body: ical(meetup(uid: 'other-1', summary: 'Other meetup')) }) do
        result = @organisation.sync_calendar_imports
      end

      assert_equal ["#{FEED_URL}: #{message}"], result[:errors]
      assert_equal 0, result[:removed]
      assert Event.find(event.id)
      assert @organisation.events.find_by(calendar_import_feed_url: OTHER_FEED_URL)
      assert_equal "#{FEED_URL}: #{message}", @organisation.reload.calendar_import_last_sync_error
    end
  end

  test "feeds and Luma's event pages are fetched with timeouts, so a slow one gives up rather than stalling the sync" do
    create_organisation(calendar_import_urls: LUMA_FEED_URL)
    page_url = 'https://luma.com/event/evt-abc'
    request_options = {}

    stub_faraday({ LUMA_FEED_URL => { status: 200, body: ical(vevent(uid: 'evt-abc@events.lu.ma', dtstart: '20270501T180000Z', summary: 'Luma event', location: 'Berlin')) },
                   page_url => { status: 200, body: '<html><head></head></html>' } },
                 request_options: request_options) do
      @organisation.sync_calendar_imports
    end

    assert_equal [LUMA_FEED_URL, page_url], request_options.keys
    request_options.each do |url, options|
      assert_equal OrganisationCalendarImports::FETCH_OPEN_TIMEOUT, options.open_timeout, url
      assert_equal OrganisationCalendarImports::FETCH_TIMEOUT, options.timeout, url
    end
  end

  test "the same event in two feeds is imported once, and is reported, while the rest of the second feed still syncs" do
    covers 'organisations/ical-event-skipped@b9bcc0'
    create_organisation(calendar_import_urls: "#{FEED_URL}\n#{OTHER_FEED_URL}")
    june = vevent(uid: 'other-june', dtstart: '20270601T180000Z', summary: 'June talk')
    leaving = vevent(uid: 'other-leaving', dtstart: '20270602T180000Z', summary: 'Leaving talk')
    stub_faraday(FEED_URL => { status: 200, body: ical(meetup) }, OTHER_FEED_URL => { status: 200, body: ical(june, leaving, name: 'Other Calendar') }) do
      @organisation.sync_calendar_imports
    end
    leaving_event = @organisation.events.find_by(calendar_import_uid: 'other-leaving')

    result = nil
    july = vevent(uid: 'other-july', dtstart: '20270701T180000Z', summary: 'July talk')
    stub_faraday(FEED_URL => { status: 200, body: ical(meetup) },
                 OTHER_FEED_URL => { status: 200, body: ical(meetup(uid: 'other-meetup'), june, july, name: 'Other Calendar') }) do
      result = @organisation.sync_calendar_imports
    end

    assert_equal 1, @organisation.events.and(name: 'Monthly meetup').count
    assert_equal FEED_URL, @organisation.events.find_by(name: 'Monthly meetup').calendar_import_feed_url
    assert @organisation.events.find_by(calendar_import_feed_url: OTHER_FEED_URL, calendar_import_uid: 'other-july'), "the feed's later events still import"
    assert @organisation.events.find_by(calendar_import_feed_url: OTHER_FEED_URL, calendar_import_uid: 'other-june')
    assert_nil Event.find(leaving_event.id), "the feed's removals still run"
    assert_equal 1, result[:removed]
    assert_equal 1, result[:created]
    assert_equal 1, result[:failed]
    assert_equal 1, result[:errors].count
    assert_match(/\A#{Regexp.escape(OTHER_FEED_URL)}: Monthly meetup on 1 May 2027 .+ wasn't imported: .*already exists/, result[:errors].first)
    @organisation.reload
    assert_equal result[:errors].first, @organisation.calendar_import_last_sync_error
    assert_equal 'Other Calendar', @organisation.calendar_import_feed_calendar_names[OTHER_FEED_URL], 'the feed still counts as read'
  end

  test 'a malformed feed is reported without touching its events' do
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup))
    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')

    [
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:broken\nDTSTART:not-a-date\nSUMMARY:Broken\nEND:VEVENT\nEND:VCALENDAR\n",
      "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:bad-zone\nSUMMARY:Bad zone\nDTSTART;TZID=Nowhere/Atlantis:2027\nEND:VEVENT\nEND:VCALENDAR\n",
      "\xFF\xFE garbage BEGIN:VCALENDAR END:VCALENDAR".b,
      '<html><body>Calendars start with BEGIN:VCALENDAR and finish with END:VCALENDAR</body></html>'
    ].each do |body|
      result = import(@organisation, body)

      assert_equal 1, result[:errors].count, body
      assert_equal 0, result[:removed], body
      assert_equal 0, result[:created], body
      assert Event.find(event.id), body
    end
  end

  test 'a large feed imports every upcoming event' do
    create_organisation(calendar_import_urls: FEED_URL)
    vevents = Array.new(60) { |i| vevent(uid: "bulk-#{i}", dtstart: (Time.utc(2027, 1, 1) + i.days).strftime('%Y%m%dT%H%M%SZ'), summary: "Day #{i}", location: 'Online') }

    result = import(@organisation, ical(*vevents))

    assert_equal 60, result[:created]
    assert_equal 60, @organisation.events.count
  end

  # ── Hostile feeds ─────────────────────────────────────────────────────────

  test 'markup in a feed is stripped from titles and kept out of RSVP links' do
    create_organisation(calendar_import_urls: FEED_URL)

    import(@organisation, ical(meetup(summary: '<b>Party</b><img src=x onerror=alert(1)>', url: 'javascript:alert(1)')))

    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')
    assert_equal 'Party', event.name
    assert_nil event.purchase_url
    assert_nil event.calendar_import_source_url
  end

  test "a feed's link to its source event can't run script on the event's edit page" do
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup))
    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')
    # As an import from before links were checked would have left it
    event.set(calendar_import_source_url: 'javascript:window.calendarImportXss=1')
    sign_in(@account)

    visit "/e/#{event.slug}/edit"

    assert page.has_content?('This event is synced from an external iCal feed')
    assert page.has_no_link?('the source event')
  end

  test "scripts in an imported event's description don't run on its page" do
    create_organisation(calendar_import_urls: FEED_URL)
    description = '<p>Welcome</p><script>window.calendarImportXss = 1</script><img src="x" onerror="window.calendarImportXss = 2">'
    import(@organisation, ical(meetup(description: description)))
    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')

    visit "/e/#{event.slug}"

    assert page.has_content?('Welcome')
    assert_nil page.evaluate_script('window.calendarImportXss')
  end

  test "a feed's calendar name and errors show as text on the iCal sync page" do
    covers_route 'GET /o/:slug/calendar_import'
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup, name: '<script>window.calendarImportXss = 1</script>Hostile'))
    @organisation.set(calendar_import_last_sync_error: "#{FEED_URL}: <img src=x onerror=window.calendarImportXss=2>")
    sign_in(@account)

    visit "/o/#{@organisation.slug}/calendar_import"

    assert page.has_content?('<script>window.calendarImportXss = 1</script>Hostile')
    assert page.has_content?('<img src=x onerror=window.calendarImportXss=2>')
    assert_nil page.evaluate_script('window.calendarImportXss')
  end

  # ── Where feeds can come from ─────────────────────────────────────────────

  test 'feed URLs on other hosts, local or private addresses, or other schemes are refused' do
    covers 'organisations/ical-supported-hosts@8e1723'
    [
      'http://localhost/feed.ics',
      'http://127.0.0.1:3000/feed.ics',
      'http://[::1]/feed.ics',
      'http://169.254.169.254/latest/meta-data/',
      'http://10.0.0.1/feed.ics',
      'http://2130706433/feed.ics',
      'https://calendar.google.com@127.0.0.1/feed.ics',
      'https://calendar.google.com.evil.example/feed.ics',
      'file:///etc/passwd',
      'ftp://calendar.google.com/feed.ics',
      'gopher://calendar.google.com:25/_HELO',
      'javascript:alert(1)',
      'calendar.google.com/feed.ics',
      'https://calendar.google.com/<bad>'
    ].each do |url|
      organisation = FactoryBot.build(:organisation, calendar_import_urls: url)
      refute organisation.valid?, url
      assert organisation.errors[:calendar_import_urls].any?, url
    end
  end

  test "a feed URL saved without validation isn't fetched unless its host is allowed" do
    create_organisation(calendar_import_urls: FEED_URL)
    @organisation.set(calendar_import_urls: "http://127.0.0.1:27017/\nfile:///etc/passwd")
    requested_urls = []

    result = stub_faraday({}, requested_urls: requested_urls) { @organisation.sync_calendar_imports }

    assert_empty requested_urls
    assert_equal 2, result[:errors].count
    assert(result[:errors].all? { |error| error.include?('iCal') })
  end

  test "a feed that redirects elsewhere isn't followed" do
    create_organisation(calendar_import_urls: FEED_URL)
    requested_urls = []

    result = stub_faraday({ FEED_URL => { status: 302, body: '', headers: { 'location' => 'http://169.254.169.254/latest/meta-data/' } } },
                          requested_urls: requested_urls) do
      @organisation.sync_calendar_imports
    end

    assert_equal [FEED_URL], requested_urls
    assert_equal ["#{FEED_URL}: iCal feed returned 302"], result[:errors]
  end

  test "Luma event pages are only fetched from Luma, and their images only from Luma's image host" do
    create_organisation(calendar_import_urls: LUMA_FEED_URL)
    requested_urls = []
    fetched_images = []
    page_url = 'https://luma.com/event/evt-abc'
    html = '<html><head><meta property="og:image" content="http://169.254.169.254/latest/meta-data/x.jpg"></head></html>'
    feed = ical(
      vevent(uid: 'evt-abc@events.lu.ma', dtstart: '20270501T180000Z', summary: 'Luma event', location: 'Berlin'),
      vevent(uid: 'other@example.com', dtstart: '20270502T180000Z', summary: 'Not on Luma', url: 'http://127.0.0.1/admin')
    )

    Dragonfly.app.stub(:fetch_url, ->(url, *) { fetched_images << url.to_s }) do
      stub_faraday({ LUMA_FEED_URL => { status: 200, body: feed },
                     page_url => { status: 307, body: '', headers: { 'location' => 'http://127.0.0.1/admin' } },
                     'http://127.0.0.1/admin' => { status: 200, body: html } },
                   requested_urls: requested_urls) do
        result = @organisation.sync_calendar_imports
        assert_equal 2, result[:created]
      end
    end

    assert_equal [LUMA_FEED_URL, page_url], requested_urls, "a redirect off Luma isn't followed, and a non-Luma URL isn't fetched"
    assert_empty fetched_images

    requested_urls.clear
    @organisation.events.each(&:destroy)
    Dragonfly.app.stub(:fetch_url, ->(url, *) { fetched_images << url.to_s }) do
      stub_faraday({ LUMA_FEED_URL => { status: 200, body: feed }, page_url => { status: 200, body: html } }, requested_urls: requested_urls) do
        @organisation.sync_calendar_imports
      end
    end
    assert_includes requested_urls, page_url
    assert_empty fetched_images, "an og:image off Luma's image host isn't fetched"
  end

  # ── Who can set up an import ──────────────────────────────────────────────

  test 'an organisation admin saves feed URLs on the iCal sync page and their events are imported' do
    covers 'organisations/ical-multiple-urls@e4d7f5'
    create_organisation
    admin = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: admin, admin: true)
    sign_in(admin)
    visit "/o/#{@organisation.slug}/calendar_import"

    fill_in 'iCal URLs', with: "#{FEED_URL}\n#{OTHER_FEED_URL.sub('https://', 'webcal://')}"
    stub_faraday(FEED_URL => { status: 200, body: ical(meetup) },
                 OTHER_FEED_URL => { status: 200, body: ical(meetup(uid: 'other-1', summary: 'Other meetup'), name: 'Other Calendar') }) do
      click_on 'Save and sync'
      assert page.has_content?('Your iCal feeds were saved and will sync in the background')
    end

    assert page.has_content?('Last synced on')
    assert page.has_content?('Community Calendar')
    assert page.has_content?('Other Calendar')
    assert_equal ['Monthly meetup', 'Other meetup'], @organisation.reload.events.pluck(:name).sort
  end

  test 'a feed URL on a host that is not supported is shown as an error and not saved' do
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/calendar_import"

    fill_in 'iCal URLs', with: 'http://127.0.0.1/feed.ics'
    click_on 'Save and sync'

    assert page.has_content?('There was an error saving your settings')
    assert page.has_content?('iCal host is not allowed')
    assert_nil @organisation.reload.calendar_import_urls
  end

  test "the iCal sync page isn't offered to people who aren't the organisation's admins" do
    create_organisation
    sign_in(FactoryBot.create(:account))

    visit "/o/#{@organisation.slug}"

    assert page.has_content?(@organisation.name)
    assert page.has_no_link?(href: "/o/#{@organisation.slug}/calendar_import")
  end

  test "only the organisation's admins can see or save its iCal feeds" do
    create_organisation
    other_admin = FactoryBot.create(:organisation).account
    event_manager = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: event_manager, event_manager: true)
    requested_urls = []

    [nil, FactoryBot.create(:account), other_admin, event_manager].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies

      get "/o/#{@organisation.slug}/calendar_import"
      assert_equal 302, last_response.status

      stub_faraday({}, requested_urls: requested_urls) do
        post "/o/#{@organisation.slug}/calendar_import", organisation: { calendar_import_urls: FEED_URL }
      end
      assert_equal 302, last_response.status
    end

    assert_nil @organisation.reload.calendar_import_urls
    assert_empty requested_urls
  end

  test "an admin can't set an organisation's sync results through the iCal sync form" do
    covers_route 'POST /o/:slug/calendar_import'
    create_organisation
    sign_in_with_rack(@account)

    %w[calendar_import_last_sync_error calendar_import_last_synced_at].each do |field|
      error = assert_raises(RuntimeError) { post "/o/#{@organisation.slug}/calendar_import", organisation: { field => 'x' } }
      assert_match(/are protected/, error.message)
    end
    assert_nil @organisation.reload.calendar_import_last_sync_error
  end
end
