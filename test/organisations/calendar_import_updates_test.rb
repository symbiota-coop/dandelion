require_relative '../test_config'
require_relative '../helpers/calendar_import_helpers'

# What happens to an organisation's imported events when its feeds change: events that move or are edited at their
# source, feeds listed more than once or in another order, and the forms a feed's times come in
class OrganisationsCalendarImportUpdatesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include CalendarImportHelpers

  # Outlook names zones the Windows way, defining them in the feed's VTIMEZONE: GMT in winter, BST in summer
  OUTLOOK_LONDON_ZONE = <<~ICAL.freeze
    BEGIN:VTIMEZONE
    TZID:GMT Standard Time
    BEGIN:STANDARD
    DTSTART:16010101T020000
    TZOFFSETFROM:+0100
    TZOFFSETTO:+0000
    RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=10
    END:STANDARD
    BEGIN:DAYLIGHT
    DTSTART:16010101T010000
    TZOFFSETFROM:+0000
    TZOFFSETTO:+0100
    RRULE:FREQ=YEARLY;INTERVAL=1;BYDAY=-1SU;BYMONTH=3
    END:DAYLIGHT
    END:VTIMEZONE
  ICAL

  # ── Events that change at their source ────────────────────────────────────

  test 'an imported event whose time, title, place and description change in the feed is updated, not duplicated' do
    covers 'organisations/ical-import-and-sync@e9f417'
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup))
    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')

    result = import(@organisation, ical(meetup(dtstart: '20270508T190000Z', dtend: '20270508T213000Z', summary: 'Monthly meetup, moved',
                                               location: 'Dalston, London', description: 'Now a week later.')))

    assert_equal({ created: 0, updated: 1, removed: 0 }, result.slice(:created, :updated, :removed))
    assert_equal [event.id], @organisation.events.pluck(:id)
    event.reload
    assert_equal 'Monthly meetup, moved', event.name
    assert_equal Time.utc(2027, 5, 8, 19), event.start_time.utc
    assert_equal Time.utc(2027, 5, 8, 21, 30), event.end_time.utc
    assert_equal 'Dalston, London', event.location
    assert_equal 'Now a week later.', event.description
  end

  test 'an imported event that loses its end in the feed lasts an hour from its start' do
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup))

    import(@organisation, ical(vevent(uid: 'meetup-1', dtstart: '20270501T180000Z', summary: 'Monthly meetup')))

    event = @organisation.events.find_by(calendar_import_uid: 'meetup-1')
    assert_equal Time.utc(2027, 5, 1, 19), event.end_time.utc
    assert_equal 'Online', event.location, 'a location dropped from the feed is dropped from the event'
  end

  test 'an event without a UID that is renamed and moved is still matched by its URL' do
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(vevent(dtstart: '20270501T180000Z', summary: 'Picnic', url: 'https://events.example.com/picnic')))
    event = @organisation.events.first

    result = import(@organisation, ical(vevent(dtstart: '20270502T120000Z', summary: 'Picnic (rain date)', url: 'https://events.example.com/picnic')))

    assert_equal({ created: 0, updated: 1, removed: 0 }, result.slice(:created, :updated, :removed))
    assert_equal [event.id], @organisation.events.pluck(:id)
    assert_equal Time.utc(2027, 5, 2, 12), event.reload.start_time.utc
  end

  test 'an event with neither UID nor URL that moves is replaced by one at its new time, rather than kept at both' do
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(vevent(dtstart: '20270501T180000Z', summary: 'Picnic')))
    event = @organisation.events.first

    result = import(@organisation, ical(vevent(dtstart: '20270502T120000Z', summary: 'Picnic')))

    assert_equal({ created: 1, removed: 1 }, result.slice(:created, :removed))
    assert_nil Event.find(event.id)
    assert_equal [Time.utc(2027, 5, 2, 12)], @organisation.reload.events.pluck(:start_time).map(&:utc)
  end

  test 'an event whose UID changes in the feed is still matched by its URL, and takes the new UID' do
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(meetup))
    event = @organisation.events.first

    result = import(@organisation, ical(meetup(uid: 'meetup-1-reissued')))

    assert_equal 0, result[:created]
    assert_equal [event.id], @organisation.events.pluck(:id)
    assert_equal 'meetup-1-reissued', event.reload.calendar_import_uid
  end

  # ── Feeds listed twice, or in another order ───────────────────────────────

  test 'a feed listed twice, once as webcal, is fetched once and makes one copy of each event' do
    create_organisation(calendar_import_urls: "#{FEED_URL}\n#{FEED_URL.sub('https://', 'webcal://')}")
    requested_urls = []

    result = import(@organisation, ical(meetup), requested_urls: requested_urls)

    assert_equal [FEED_URL], requested_urls
    assert_equal({ created: 1, skipped: 0 }, result.slice(:created, :skipped))
    assert_empty result[:errors]
    assert_equal 1, @organisation.events.count
  end

  test 'when two feeds have the same event, the copy from the feed listed first is the one imported' do
    covers 'organisations/ical-event-skipped@b9bcc0'
    create_organisation(calendar_import_urls: "#{OTHER_FEED_URL}\n#{FEED_URL}")

    result = stub_faraday(FEED_URL => { status: 200, body: ical(meetup) },
                          OTHER_FEED_URL => { status: 200, body: ical(meetup(uid: 'other-meetup', url: 'https://other.example.com/meetup')) }) do
      @organisation.sync_calendar_imports
    end

    assert_equal 1, @organisation.events.count
    event = @organisation.events.first
    assert_equal OTHER_FEED_URL, event.calendar_import_feed_url
    assert_equal 'https://other.example.com/meetup', event.purchase_url
    assert_equal 1, result[:failed]
    assert result[:errors].first.start_with?("#{FEED_URL}: Monthly meetup")
  end

  test "the iCal sync page lists each feed's calendar once, in the order the feeds are listed" do
    create_organisation(calendar_import_urls: FEED_URL)
    # As saved before the URLs were checked, with one no longer allowed, a feed listed twice and one never read
    @organisation.set(calendar_import_urls: "#{OTHER_FEED_URL}\nhttp://127.0.0.1/feed.ics\n#{FEED_URL}\n#{OTHER_FEED_URL.sub('https://', 'webcal://')}\n" \
                                            'https://calendars.icloud.com/never-read.ics',
                      calendar_import_feed_calendar_names: { FEED_URL => 'Community Calendar', OTHER_FEED_URL => 'Other Calendar' },
                      calendar_import_last_synced_at: Time.now)
    sign_in(@account)

    visit "/o/#{@organisation.slug}/calendar_import"

    assert page.has_content?('Last synced on')
    assert_equal ["Other Calendar #{OTHER_FEED_URL}", "Community Calendar #{FEED_URL}"], (page.all('li:has(code)').map { |li| li.text.squish })
  end

  # ── Times in the forms feeds give them ────────────────────────────────────

  test 'times in UTC, in a named zone, or in a zone the feed defines land on the same moment' do
    covers 'organisations/ical-import-and-sync@e9f417'
    create_organisation(calendar_import_urls: FEED_URL)
    feed = ical(
      vevent(uid: 'utc', dtstart: '20270601T170000Z', dtend: '20270601T190000Z', summary: 'In UTC'),
      vevent(uid: 'named', dtstart: ';TZID=Europe/London:20270601T180000', dtend: ';TZID=Europe/London:20270601T200000', summary: 'In London'),
      vevent(uid: 'new-york', dtstart: ';TZID=America/New_York:20270601T130000', dtend: ';TZID=America/New_York:20270601T150000', summary: 'In New York'),
      vevent(uid: 'outlook', dtstart: ';TZID=GMT Standard Time:20270601T180000', dtend: ';TZID=GMT Standard Time:20270601T200000', summary: 'From Outlook')
    ).sub('VERSION:2.0', "VERSION:2.0\n#{OUTLOOK_LONDON_ZONE.chomp}")

    import(@organisation, feed)

    %w[utc named new-york outlook].each do |uid|
      event = @organisation.events.find_by(calendar_import_uid: uid)
      assert_equal Time.utc(2027, 6, 1, 17), event.start_time.utc, uid
      assert_equal Time.utc(2027, 6, 1, 19), event.end_time.utc, uid
    end
  end

  test "a time given without a zone is taken in the organisation's time zone, as all-day dates are" do
    covers 'organisations/ical-times-without-zone@036a3a'
    create_organisation(calendar_import_urls: FEED_URL, time_zone: 'America/New_York')

    import(@organisation, ical(vevent(uid: 'floating', dtstart: '20270601T180000', dtend: '20270601T200000', summary: 'Floating'),
                               vevent(uid: 'all-day', dtstart: ';VALUE=DATE:20270602', summary: 'All day')))

    new_york = Time.find_zone!('America/New_York')
    floating = @organisation.events.find_by(calendar_import_uid: 'floating')
    assert_equal new_york.local(2027, 6, 1, 18), floating.start_time
    assert_equal new_york.local(2027, 6, 1, 20), floating.end_time
    all_day = @organisation.events.find_by(calendar_import_uid: 'all-day')
    assert_equal new_york.local(2027, 6, 2), all_day.start_time
    assert_equal new_york.local(2027, 6, 2, 1), all_day.end_time, 'an all-day date without an end lasts an hour'
  end

  test 'an event that changes from all day to a time in the feed moves to that time' do
    create_organisation(calendar_import_urls: FEED_URL)
    import(@organisation, ical(vevent(uid: 'day-1', dtstart: ';VALUE=DATE:20270610', dtend: ';VALUE=DATE:20270611', summary: 'Open day')))
    event = @organisation.events.first

    result = import(@organisation, ical(vevent(uid: 'day-1', dtstart: '20270610T090000Z', dtend: '20270610T170000Z', summary: 'Open day')))

    assert_equal 1, result[:updated]
    event.reload
    assert_equal Time.utc(2027, 6, 10, 9), event.start_time.utc
    assert_equal Time.utc(2027, 6, 10, 17), event.end_time.utc
  end
end
