require_relative '../test_config'

# An organisation's public events listing (/o/:slug/events in HTML, JSON and ICS), its events block, and the admins'
# event lookup and stats: what each lists, and to whom
class EventOrganisationListingsTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # The events listing's pagelets (and the calendar and map) load by XHR. The referer is the one an embedding page
  # sends: Rack::Attack challenges a search without one
  def xhr_get(path, params = {})
    get path, params, { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest', 'HTTP_REFERER' => 'https://example.com/' }
  end

  def listing_path(format = nil)
    "/o/#{@organisation.slug}/events#{".#{format}" if format}"
  end

  # The organisation's own public event, one it cohosts, and the events its listings must leave out: its secret, locked
  # and deleted events and another organisation's
  def create_listing_events
    create_event(as: :public_event, name: 'Open public event')
    other_organisation = FactoryBot.create(:organisation)
    @cohosted_event = FactoryBot.create(:event, organisation: other_organisation, name: 'Cohosted public event')
    @cohosted_event.cohostships.create!(organisation: @organisation)
    @other_event = FactoryBot.create(:event, organisation: other_organisation, name: 'Elsewhere event')
    create_event(as: :secret_event, name: 'Hush secret event', secret: true)
    create_event(as: :locked_event, name: 'Bolted locked event', locked: true)
    create_event(as: :deleted_event, name: 'Binned deleted event')
    @deleted_event.destroy
    [@public_event, @cohosted_event, @other_event, @secret_event, @locked_event, @deleted_event].each { |event| event.set(coordinates: [18.06, 59.33]) }
  end

  def hidden_events
    [@other_event, @secret_event, @locked_event, @deleted_event]
  end

  def assert_lists(body, shown, hidden)
    shown.each { |event| assert_includes body, event.name }
    hidden.each { |event| refute_includes body, event.name }
  end

  def json_ids
    JSON.parse(last_response.body).map { |event| event['id'] }
  end

  test "the listing shows the organisation's own and cohosted public events, never secret, locked, deleted or another organisation's" do
    create_listing_events

    xhr_get listing_path
    assert_equal 200, last_response.status
    assert_lists last_response.body, [@public_event, @cohosted_event], hidden_events

    xhr_get listing_path, minimal: 1
    assert_lists last_response.body, [@public_event, @cohosted_event], hidden_events

    # The full page loads the list as a pagelet, and names none of the hidden events itself
    get listing_path
    assert_equal 200, last_response.status
    hidden_events.each { |event| refute_includes last_response.body, event.name }
  end

  test 'locked events stay out of the listing even for a signed-in visitor who is no admin of them' do
    create_listing_events
    sign_in_with_rack(FactoryBot.create(:account))

    xhr_get listing_path
    assert_lists last_response.body, [@public_event], [@locked_event, @secret_event]
  end

  test 'the JSON listing, and its calendar and map views, follow the same rules' do
    create_listing_events

    xhr_get listing_path(:json)
    assert_equal 200, last_response.status
    assert_equal [@public_event.id.to_s, @cohosted_event.id.to_s].sort, json_ids.sort

    xhr_get listing_path(:json), display: 'calendar'
    assert_equal [@public_event.id.to_s, @cohosted_event.id.to_s].sort, json_ids.sort

    xhr_get listing_path(:json), display: 'map', west: 17, south: 59, east: 19, north: 60
    assert_equal 2, JSON.parse(last_response.body)['pointsCount']
  end

  test 'the JSON listing gives the fields embeds rely on' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, name: 'Breathwork')
    local_group = FactoryBot.create(:local_group, organisation: @organisation, name: 'Stockholm')
    create_event(name: 'Fielded event', activity: activity, local_group: local_group, description: '<p>All about it</p>')
    @event.event_tagships.create!(event_tag: FactoryBot.create(:event_tag, name: 'breath'))
    cohost = FactoryBot.create(:organisation, name: 'Cohost Org')
    @event.cohostships.create!(organisation: cohost)

    xhr_get listing_path(:json)
    event = JSON.parse(last_response.body).sole
    assert_equal({ 'id' => @event.id.to_s, 'slug' => @event.slug, 'url' => "#{ENV['BASE_URI']}/e/#{@event.slug}", 'name' => 'Fielded event',
                   'location' => @event.location, 'description' => '<p>All about it</p>', 'tags' => ['breath'],
                   'activity' => { 'name' => 'Breathwork', 'id' => activity.id.to_s }, 'local_group' => { 'name' => 'Stockholm', 'id' => local_group.id.to_s },
                   'cohosts' => [{ 'name' => 'Cohost Org', 'slug' => cohost.slug }] },
                 event.slice('id', 'slug', 'url', 'name', 'location', 'description', 'tags', 'activity', 'local_group', 'cohosts'))
    assert_equal @event.start_time.to_i, Time.parse(event['start_time']).to_i
    assert_equal @event.end_time.to_i, Time.parse(event['end_time']).to_i
  end

  test 'the ICS feed parses, is named for the organisation, and lists only its own and cohosted public events' do
    create_listing_events
    create_event(as: :recent_event, name: 'Last week event', start_time: 1.week.ago, end_time: 1.week.ago + 2.hours)
    create_event(as: :old_event, name: 'Long ago event', start_time: 2.months.ago, end_time: 2.months.ago + 2.hours)
    create_event(:evergreen, as: :evergreen_event, name: 'Always on event')

    get listing_path(:ics)
    assert_equal 200, last_response.status
    calendar = Icalendar::Calendar.parse(last_response.body).sole
    assert_equal [@organisation.name], calendar.custom_property('x_wr_calname').map(&:to_s)
    # Events from the last month too, but none without a date
    assert_equal [@public_event, @cohosted_event, @recent_event].map { |event| event.id.to_s }.sort, calendar.events.map { |event| event.uid.to_s }.sort
    assert_equal "#{ENV['BASE_URI']}/e/#{@public_event.slug}", calendar.events.detect { |event| event.uid.to_s == @public_event.id.to_s }.description.to_s
  end

  test 'activity, local group, tag, search, date and online filters narrow the listing' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    tag = FactoryBot.create(:event_tag, name: 'dance')
    create_event(as: :activity_event, name: 'Activity only event', activity: activity, start_time: 10.days.from_now, end_time: 10.days.from_now + 2.hours)
    create_event(as: :local_group_event, name: 'Local group only event', local_group: local_group, start_time: 20.days.from_now, end_time: 20.days.from_now + 2.hours)
    create_event(as: :tagged_event, name: 'Tagged only event', start_time: 30.days.from_now, end_time: 30.days.from_now + 2.hours)
    @tagged_event.event_tagships.create!(event_tag: tag)
    create_event(as: :online_event, name: 'Zoomable gathering', location: 'Online', start_time: 40.days.from_now, end_time: 40.days.from_now + 2.hours)
    all = [@activity_event, @local_group_event, @tagged_event, @online_event]

    {
      { activity_id: activity.id.to_s } => [@activity_event],
      { local_group_id: local_group.id.to_s } => [@local_group_event],
      { event_tag_id: tag.id.to_s } => [@tagged_event],
      { event_type: 'dance' } => [@tagged_event],
      { event_type: 'no-such-tag' } => [],
      { q: 'zoomable' } => [@online_event],
      { online: 1 } => [@online_event],
      { in_person: 1 } => [@activity_event, @local_group_event, @tagged_event],
      { from: 15.days.from_now.to_date.to_s } => [@local_group_event, @tagged_event, @online_event],
      { from: 15.days.from_now.to_date.to_s, to: 25.days.from_now.to_date.to_s } => [@local_group_event]
    }.each do |filter, shown|
      xhr_get listing_path, filter
      assert_equal 200, last_response.status
      assert_lists last_response.body, shown, all - shown

      xhr_get listing_path(:json), filter
      assert_equal shown.map { |event| event.id.to_s }.sort, json_ids.sort, "JSON with #{filter}"
    end
  end

  test 'past=1 lists past events, most recent first, but not the past events it only cohosts' do
    create_event(as: :older_event, name: 'Older past event', start_time: 10.days.ago, end_time: 10.days.ago + 2.hours)
    create_event(as: :newer_event, name: 'Newer past event', start_time: 3.days.ago, end_time: 3.days.ago + 2.hours)
    create_event(as: :secret_past_event, name: 'Hush past event', secret: true, start_time: 4.days.ago, end_time: 4.days.ago + 2.hours)
    create_event(as: :upcoming_event, name: 'Upcoming event')
    cohosted = FactoryBot.create(:event, organisation: FactoryBot.create(:organisation), name: 'Cohosted past event', start_time: 5.days.ago, end_time: 5.days.ago + 2.hours)
    cohosted.cohostships.create!(organisation: @organisation)

    xhr_get listing_path, past: 1
    body = last_response.body
    assert_lists body, [@newer_event, @older_event], [@upcoming_event, @secret_past_event, cohosted]
    assert_operator body.index('Newer past event'), :<, body.index('Older past event')

    xhr_get listing_path
    assert_lists last_response.body, [@upcoming_event], [@newer_event, @older_event]
  end

  test 'the listing is soonest first, or newest first with order=created_at, and pages by per_page' do
    create_event(as: :later_event, name: 'Third soonest event', start_time: 30.days.from_now, end_time: 30.days.from_now + 2.hours, created_at: 3.days.ago)
    create_event(as: :soonest_event, name: 'First soonest event', start_time: 10.days.from_now, end_time: 10.days.from_now + 2.hours, created_at: 1.day.ago)
    create_event(as: :middle_event, name: 'Second soonest event', start_time: 20.days.from_now, end_time: 20.days.from_now + 2.hours, created_at: 2.days.ago)

    xhr_get listing_path
    body = last_response.body
    assert_operator body.index('First soonest event'), :<, body.index('Second soonest event')
    assert_operator body.index('Second soonest event'), :<, body.index('Third soonest event')

    xhr_get listing_path, order: 'created_at'
    body = last_response.body
    assert_operator body.index('First soonest event'), :<, body.index('Second soonest event')
    assert_operator body.index('Second soonest event'), :<, body.index('Third soonest event')
    @soonest_event.set(created_at: 5.days.ago)
    xhr_get listing_path, order: 'created_at'
    body = last_response.body
    assert_operator body.index('Second soonest event'), :<, body.index('Third soonest event')
    assert_operator body.index('Third soonest event'), :<, body.index('First soonest event')

    xhr_get listing_path, per_page: 2
    assert_lists last_response.body, [@soonest_event, @middle_event], [@later_event]
    assert_includes last_response.body, 'page=2'
    xhr_get listing_path, per_page: 2, page: 2
    assert_lists last_response.body, [@later_event], [@soonest_event, @middle_event]
  end

  test 'minimal=1 renders the embed layout, which may be framed, with the events only shown in embeds' do
    create_event(name: 'Everywhere event')
    create_event(as: :embed_event, name: 'Embed only event', minimal_only: true)

    get listing_path, minimal: 1
    assert_equal 200, last_response.status
    assert_nil last_response.headers['X-Frame-Options']
    refute_includes last_response.body, "'s events"
    assert_includes last_response.body, 'id="events-container"'
    xhr_get listing_path, minimal: 1
    assert_lists last_response.body, [@event, @embed_event], []

    get listing_path
    assert_equal 'SAMEORIGIN', last_response.headers['X-Frame-Options']
    assert_includes last_response.body, "'s events"
    xhr_get listing_path
    assert_lists last_response.body, [@event], [@embed_event]
  end

  test "the events block lists the organisation's upcoming public events, ten a page, and members_events just members' events" do
    create_listing_events
    create_event(as: :past_event, name: 'Bygone event', start_time: 3.days.ago, end_time: 3.days.ago + 2.hours)
    create_event(as: :members_event, name: 'Donors only event', monthly_donors_only: true)
    path = "/o/#{@organisation.slug}/events_block"

    xhr_get path
    assert_equal 200, last_response.status
    assert_lists last_response.body, [@public_event, @cohosted_event, @members_event], hidden_events + [@past_event]

    xhr_get path, members_events: 1
    assert_lists last_response.body, [@members_event], [@public_event, @cohosted_event]

    10.times { |i| create_event(as: :"filler#{i}", name: "Filler #{i} event", start_time: 1.day.from_now + i.hours, end_time: 1.day.from_now + i.hours + 1.hour) }
    xhr_get path
    assert_equal 10, last_response.body.scan(/Filler \d event/).size
    assert_includes last_response.body, 'events_page=2'
    xhr_get path, events_page: 2
    assert_lists last_response.body, [@public_event, @cohosted_event, @members_event], [@filler0]
  end

  test 'event stats are refused to visitors and to signed-in people who are no admin of the organisation, without their data' do
    create_listing_events
    path = "/o/#{@organisation.slug}/events/stats"

    [nil, FactoryBot.create(:account)].each do |account|
      sign_in_with_rack(account) if account
      [[path, { table: 1 }], ["#{path}.csv", {}], [path, { deleted: 1, table: 1 }]].each do |stats_path, params|
        get stats_path, params
        assert last_response.redirect?
        assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
        [@public_event, @secret_event, @locked_event, @deleted_event].each { |event| refute_includes last_response.body, event.name }
      end
      xhr_get path, table: 1
      assert_equal 403, last_response.status
      refute_includes last_response.body, @secret_event.name
    end
  end

  def lookup_ids
    JSON.parse(last_response.body)['results'].map { |result| result['id'] }
  end

  test "the event lookup gives an organisation's admins its own and cohosted events, secret and locked ones too, and nobody else any" do
    create_listing_events
    path = "/o/#{@organisation.id}/events/lookup.json"

    xhr_get path
    assert_equal 403, last_response.status
    refute_includes last_response.body, @secret_event.name
    get path
    assert last_response.redirect?
    refute_includes last_response.body, @secret_event.name

    other_admin = @other_event.organisation.account
    sign_in_with_rack(other_admin)
    xhr_get path
    assert_equal 403, last_response.status

    sign_in_with_rack(@account)
    xhr_get path
    assert_equal 200, last_response.status
    results = JSON.parse(last_response.body)['results']
    assert_equal [@public_event, @cohosted_event, @secret_event, @locked_event].map { |event| event.id.to_s }.sort, results.map { |result| result['id'] }.sort
    assert_equal "#{@public_event.name} (#{@public_event.start_time.to_date})", results.detect { |result| result['id'] == @public_event.id.to_s }['text']

    xhr_get path, q: 'hush'
    assert_equal [@secret_event.id.to_s], lookup_ids
    xhr_get path, id: @cohosted_event.id.to_s
    assert_equal [@cohosted_event.id.to_s], lookup_ids
    xhr_get path, id: @other_event.id.to_s
    assert_empty JSON.parse(last_response.body)['results']
  end

  test 'odd params give a listing, not an error, and never widen it to hidden events' do
    create_listing_events
    [
      { from: 'not-a-date' }, { to: 'not-a-date' }, { from: '2026-13-45' }, { from: { 'x' => '2026-01-01' } }, { to: %w[2026-01-01] }, { from: 'not-a-date', order: 'random' },
      { page: '99999999999999999999' }, { page: '-1' }, { page: 'abc' }, { per_page: '0' }, { per_page: '-5' },
      { local_group_id: { '$ne' => 'x' } }, { activity_id: { '$exists' => true } }, { activity_id: %w[a b] }, { local_group_id: 'nonsense' },
      { event_tag_id: { '$ne' => '1' } }, { q: { '$ne' => '1' } }, { q: 'x' * 500 }, { order: { '$ne' => 1 } },
      { carousel_ids: { '$ne' => 'x' } }, { near: 'nowhere-at-all' }, { secret: true }, { locked: true }
    ].each do |params|
      [listing_path, listing_path(:json)].each do |path|
        xhr_get path, params
        assert_equal 200, last_response.status, "#{path} #{params}"
        hidden_events.each { |event| refute_includes last_response.body, event.name, "#{path} #{params}" }
      end
    end
    get listing_path(:ics), q: { 'a' => 'b' }
    assert_equal 200, last_response.status
    xhr_get "/o/#{@organisation.slug}/events_block", events_page: '99999999999999999999'
    assert_equal 200, last_response.status
  end
end
