require_relative '../test_config'

# Event listings, cards, embeds and stats, and the queries they run
class EventListingsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # An event of a stripe-connected organisation with a coordinator, facilitator, tag, a checked-in ticket, donation,
  # charge, rpayment and feedback, for the stats table and CSV
  def create_stats_event(as)
    create_organisation unless @organisation
    @organisation.set(stripe_client_id: 'ca_test')
    attendee = Account.find_by(name: 'Ada Lovelace') || FactoryBot.create(:account, name: 'Ada Lovelace')
    coordinator = Account.find_by(name: 'Coco Ordinator') || FactoryBot.create(:account, name: 'Coco Ordinator')
    facilitator = Account.find_by(name: 'Fay Cilitator') || FactoryBot.create(:account, name: 'Fay Cilitator')
    tag = EventTag.find_by(name: 'wellbeing') || FactoryBot.create(:event_tag, name: 'wellbeing')
    event = create_event(prices: [10], as: as, coordinator: coordinator, facebook_event_url: 'https://www.facebook.com/events/1')
    event.event_facilitations.create!(account: facilitator)
    event.event_tagships.create!(event_tag: tag)
    order = event.orders.create!(account: attendee, currency: 'GBP', value: 10, payment_completed: true, payment_intent: "pi_#{as}")
    event.tickets.create!(account: attendee, order: order, ticket_type: event.ticket_types.first, payment_completed: true, checked_in: true)
    event.donations.create!(account: attendee, order: order, amount: 5, payment_completed: true)
    @organisation.stripe_charges.create!(event: event, order: order, amount: 1500, currency: 'GBP', balance_float: 15, fees_float: 0.5, de_donation_revenue: 5)
    event.rpayments.create!(account: @account, amount: 1, currency: 'GBP', role: 'organiser')
    event.event_feedbacks.create!(account: attendee, rating: 4)
    event
  end

  # The response body of the request the block makes, and how many Mongo commands it ran
  def mongo_commands_during
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |e| commands << e.command_name }
    subscriber.define_singleton_method(:succeeded) { |_| nil }
    subscriber.define_singleton_method(:failed) { |_| nil }
    Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    yield
    [last_response.body, commands.size]
  ensure
    Mongoid.default_client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber)
  end

  test 'upcoming events on the home page show whether each is starred, with the page' do
    create_event(as: :starred_event)
    create_event(as: :unstarred_event)
    @unstarred_event.tickets.create!(account: @account, ticket_type: FactoryBot.create(:ticket_type, event: @unstarred_event), payment_completed: true)
    @starred_event.event_stars.create!(account: @account)

    sign_in_with_rack(@account)
    get '/'
    assert_includes last_response.body, %(href="/e/#{@starred_event.slug}/unstar")
    assert_includes last_response.body, %(href="/e/#{@unstarred_event.slug}/do_star")
  end

  test 'trending ranks events by their paid orders in the last week, then the soonest of the rest' do
    create_event(as: :quiet_soon, start_time: 2.days.from_now, end_time: 3.days.from_now)
    create_event(as: :quiet_later, start_time: 5.days.from_now, end_time: 6.days.from_now)
    create_event(as: :busy, start_time: 10.days.from_now, end_time: 11.days.from_now)
    create_event(as: :busier, start_time: 20.days.from_now, end_time: 21.days.from_now)
    # trending only ranks events that could be on the homepage
    [@quiet_soon, @quiet_later, @busy, @busier].each { |event| event.set(browsable: true, has_image: true, hidden_from_homepage: false) }
    [@busy, @busier, @busier].each do |event|
      Order.create!(event: event, account: FactoryBot.create(:account), value: 10, payment_completed: true, currency: 'GBP')
    end
    Order.create!(event: @quiet_later, account: FactoryBot.create(:account), value: 10, payment_completed: true, currency: 'GBP').set(created_at: 2.weeks.ago)
    Order.create!(event: @quiet_soon, account: FactoryBot.create(:account), value: 10, payment_completed: false, currency: 'GBP')
    events = Event.and(:id.in => [@quiet_soon.id, @quiet_later.id, @busy.id, @busier.id])

    assert_equal [@busier.id, @busy.id, @quiet_soon.id, @quiet_later.id], events.trending.map(&:id)
    assert_equal [@busier.id, @busy.id, @quiet_soon.id], events.trending(limit: 3).map(&:id)

    @quiet_later.set(trending: true)
    assert_equal [@quiet_later.id, @busier.id], events.trending(limit: 2).map(&:id)
  end

  test 'EventIds pages through events in the given order, loading only the page' do
    events = 5.times.map { |i| create_event(as: :"event#{i}") }
    ids = EventIds.new([events[3], events[0], events[4], events[1], events[2]].map(&:id))

    page = ids.paginate(page: 2, per_page: 2)
    assert_equal [events[4], events[1]], page.to_a
    assert_equal 5, page.total_entries
    assert_equal 3, page.total_pages
  end

  test 'event cards read tags and cohosts from the joins with_key_includes preloads, without querying' do
    create_event
    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    tag = FactoryBot.create(:event_tag)
    @event.event_tagships.create!(event_tag: tag)

    preloaded = Event.and(id: @event.id).with_key_includes.first
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |e| commands << e.command_name }
    subscriber.define_singleton_method(:succeeded) { |_| nil }
    subscriber.define_singleton_method(:failed) { |_| nil }
    Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    assert_equal [tag], preloaded.event_tagships.map(&:event_tag)
    assert_equal [cohost], preloaded.cohostships.map(&:organisation)
    preloaded.image_source(cohost)
    assert_empty commands
  ensure
    Mongoid.default_client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber) if subscriber
  end

  test 'events stats CSV reads every event with the same queries, however many events there are' do
    create_stats_event(:event1)
    sign_in_with_rack(@account)
    body, one_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s }
    row = CSV.parse(body, headers: true).first
    assert_equal 'Coco Ordinator', row['coordinator']
    assert_includes row['facilitators'], 'Fay Cilitator'
    assert_equal 'wellbeing', row['tags']
    assert_equal '1/1', row['checked_in']
    assert_equal '£10, £10', row['ticket_revenue']
    assert_equal '£15 from 1 order', row['revenue_reported_by_dandelion']
    assert_equal '£15 from 1 charge', row['revenue_reported_by_stripe']
    assert_equal '1 response, (100%), 4.0', row['feedback']
    assert_equal 'https://www.facebook.com/events/1', row['facebook_event']

    create_stats_event(:event2)
    create_stats_event(:event3)
    body, three_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s }
    assert_equal 3, CSV.parse(body, headers: true).size
    assert_equal one_event_commands, three_event_commands
  end

  test "events stats CSV splits an order's credit with a revenue sharer with the same queries, however many events there are" do
    sharer = FactoryBot.create(:account, name: 'Rev Sharer')
    share_revenue = lambda do |event|
      event.set(revenue_sharer_id: sharer.id, revenue_share_to_revenue_sharer: 50)
      event.tickets.each { |ticket| ticket.set(organisation_revenue_share: 0.5) }
      event.orders.each { |order| order.set(revenue_sharer_id: sharer.id, organisation_revenue_share: 0.5, credit_applied: 3) }
    end
    share_revenue.call(create_stats_event(:event1))
    sign_in_with_rack(@account)
    body, one_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s }
    # £5 of the £10 tickets, less the sharer's part of the £3 credit: £3 × (£10 / £15) × 0.5 = £1
    assert_includes CSV.parse(body, headers: true).first['ticket_revenue_to_revenue_sharer'], '£4'

    share_revenue.call(create_stats_event(:event2))
    share_revenue.call(create_stats_event(:event3))
    body, three_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s }
    assert_equal 3, CSV.parse(body, headers: true).size
    assert_equal one_event_commands, three_event_commands
  end

  test 'events stats page loads its table in a request of its own, which renders every row with the same queries however many events there are' do
    create_stats_event(:event1)
    # Every row shows the coordinator's avatar, whose url's Dragonfly job is found once for the table. Stored, and its
    # thumbnail's job recorded, directly, as an earlier upload and page view would have left them, so the test doesn't
    # need ImageMagick
    coordinator = @event1.coordinator
    coordinator.set(image_uid: Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg')))
    DragonflyJob.create!(signature: coordinator.image.thumb('400x400#').signature, uid: Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg')))
    sign_in_with_rack(@account)
    page, one_event_page_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s }
    assert_includes page, %(data-pagelet-url="/o/#{@organisation.slug}/events/stats?from=#{Rack::Utils.escape(Date.today.to_s)}&amp;table=1")
    refute_includes page, '1/1 tickets sold'
    body, one_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s, table: 1 }
    assert_includes body, 'Coco Ordinator'
    assert_includes body, 'Fay Cilitator'
    assert_includes body, 'wellbeing'
    assert_includes body, '1/1 tickets sold'
    assert_includes body, '1 order</a>'
    assert_includes body, '1 response'
    refute_includes body, 'data-pagelet-url'

    create_stats_event(:event2)
    create_stats_event(:event3)
    _, three_event_page_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s }
    assert_equal one_event_page_commands, three_event_page_commands
    body, three_event_commands = mongo_commands_during { get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s, table: 1 }
    assert_equal 3, body.scan('1 response').size
    assert_equal one_event_commands, three_event_commands
  end

  test 'signed-out visitors start the events map by interacting with the page' do
    visit '/events'
    assert page.has_css?('a[rel=nofollow][aria-label="Map view"]')
    visit '/events?display=map'
    assert page.has_css?('#map-start', text: 'Click to view map')
    assert page.has_no_css?('#map-canvas', visible: true)
    # Stands in for Google Maps, which bills each map load
    execute_script 'DandelionMap.initializeMap = function () { window.mapStarted = true }'
    find('#map-start').hover
    assert page.has_css?('#map-canvas', visible: true)
    assert page.has_no_css?('#map-start')
    assert evaluate_script('window.mapStarted')
  end

  test "event stats lists all of an organisation's events, including secret and locked ones" do
    covers 'events/event-stats-all-events@6626d6'
    create_event(as: :event1, name: 'Open stats event', prices: [0])
    create_event(as: :event2, name: 'Secret stats event', prices: [0], secret: true)
    create_event(as: :event3, name: 'Locked stats event', prices: [0], locked: true)
    sign_in_with_rack(@account)

    get "/o/#{@organisation.slug}/events/stats", from: Date.today.to_s, table: 1
    assert_equal 200, last_response.status
    ['Open stats event', 'Secret stats event', 'Locked stats event'].each { |name| assert_includes last_response.body, name }

    get "/o/#{@organisation.slug}/events/stats.csv", from: Date.today.to_s
    assert_equal ['Locked stats event', 'Open stats event', 'Secret stats event'], CSV.parse(last_response.body, headers: true).map { |row| row['name'] }.sort
  end

  test 'embed listing parameters hide the featured title, search, view options, listings and later carousels' do
    covers 'events/embed-listing-params@d85f53'
    create_event(name: 'Featured embed event', prices: [0])
    @event.set(featured: true, has_image: true)
    carousel1 = @organisation.carousels.create!(name: 'First carousel')
    carousel2 = @organisation.carousels.create!(name: 'Second carousel')

    get "/o/#{@organisation.slug}/events", minimal: 1
    assert_includes last_response.body, 'id="events-search-near"'
    assert_includes last_response.body, 'aria-label="View as"'
    assert_includes last_response.body, "carousels/featured?hide_featured_title=\""
    assert_includes last_response.body, "id=\"carousel-#{carousel1.id}\""
    assert_includes last_response.body, "id=\"carousel-#{carousel2.id}\""
    get "/o/#{@organisation.slug}/carousels/featured"
    assert_includes last_response.body, '<h2 class="text-center">Featured</h2>'
    xhr_get "/o/#{@organisation.slug}/events", minimal: 1
    assert_includes last_response.body, 'Featured embed event'

    get "/o/#{@organisation.slug}/events", minimal: 1, hide_featured_title: 1, no_search: 1, first_carousel_only: 1
    refute_includes last_response.body, 'id="events-search-near"'
    assert_includes last_response.body, 'aria-label="View as"'
    assert_includes last_response.body, 'carousels/featured?hide_featured_title=1'
    assert_includes last_response.body, "id=\"carousel-#{carousel1.id}\""
    refute_includes last_response.body, "id=\"carousel-#{carousel2.id}\""
    get "/o/#{@organisation.slug}/carousels/featured", hide_featured_title: 1
    assert_includes last_response.body, 'slick-item'
    refute_includes last_response.body, '<h2 class="text-center">Featured</h2>'

    get "/o/#{@organisation.slug}/events", minimal: 1, no_search: 1, no_view_options: 1
    refute_includes last_response.body, 'id="events-search-near"'
    refute_includes last_response.body, 'aria-label="View as"'

    xhr_get "/o/#{@organisation.slug}/events", minimal: 1, no_listings: 1
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'Featured embed event'
  end

  test 'embed listings with recordings=1 show past events with a recording, most recent first, and past=1 all past events' do
    covers 'events/embed-recordings-param@50657a', 'events/embed-past-param@02bb96'
    create_event(as: :event1, name: 'Older recorded event', prices: [0], start_time: 10.days.ago, end_time: 10.days.ago + 2.hours, extra_info_for_recording_email: '<p>Recording</p>')
    create_event(as: :event2, name: 'Newer recorded event', prices: [0], start_time: 3.days.ago, end_time: 3.days.ago + 2.hours, extra_info_for_recording_email: '<p>Recording</p>')
    create_event(as: :event3, name: 'Unrecorded past event', prices: [0], start_time: 5.days.ago, end_time: 5.days.ago + 2.hours)
    create_event(as: :event4, name: 'Upcoming event', prices: [0])

    xhr_get "/o/#{@organisation.slug}/events", minimal: 1, recordings: 1
    body = last_response.body
    assert_includes body, 'Newer recorded event'
    assert_includes body, 'Older recorded event'
    assert_operator body.index('Newer recorded event'), :<, body.index('Older recorded event')
    refute_includes body, 'Unrecorded past event'
    refute_includes body, 'Upcoming event'

    carousel = @organisation.carousels.create!(name: 'A carousel')
    get "/o/#{@organisation.slug}/events", minimal: 1, recordings: 1
    assert_includes last_response.body, "id=\"carousel-#{carousel.id}\""
    # With the referer the embedding page sends: Rack::Attack challenges a search without one
    get "/o/#{@organisation.slug}/events", { minimal: 1, recordings: 1, search: 1, display: 'grid' }, { 'HTTP_REFERER' => 'https://example.com/' }
    refute_includes last_response.body, "id=\"carousel-#{carousel.id}\""
    assert_includes last_response.body, 'id="events-grid"'

    xhr_get "/o/#{@organisation.slug}/events", minimal: 1, past: 1
    body = last_response.body
    ['Newer recorded event', 'Unrecorded past event', 'Older recorded event'].each { |name| assert_includes body, name }
    refute_includes body, 'Upcoming event'
  end
end
