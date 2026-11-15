require_relative '../test_config'

class EventBoostsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  test 'buying a boost starts a Stripe checkout, and once paid the boost shows in the boosts history as Upcoming' do
    covers_route 'GET /e/:slug/boosts'
    covers_route 'POST /e/:slug/boosts'
    create_event(prices: [0])

    sign_in(@account)
    visit "/e/#{@event.slug}/boosts"

    start_time = (Time.zone.now.beginning_of_hour + 2.hours).strftime('%Y-%m-%d %H:%M')
    execute_script %(document.getElementById('event_boost_start_time').value = #{start_time.to_json})
    fill_in 'event_boost_hours', with: 1
    fill_in 'event_boost_hourly_amount', with: 10

    stripe_session = api_object(id: 'cs_complete_me', payment_intent: 'pi_test')
    Stripe::Checkout::Session.stub :create, stripe_session do
      record_stripe_redirect
      click_button 'Buy boost'
      # The boost is saved by a background request. Waiting for its answer here, inside the stub, also keeps the
      # request from reaching the real Stripe
      assert has_checkout_session?('cs_complete_me')
    end

    event_boost = @event.event_boosts.order('created_at desc').first
    assert_equal 'cs_complete_me', event_boost.session_id
    assert_equal 'pi_test', event_boost.payment_intent
    refute event_boost.payment_completed?
    # As Stripe's webhook would once the checkout is paid
    event_boost.set(payment_completed: true)

    visit "/e/#{@event.slug}/boosts"

    assert page.has_content?('Upcoming')
  end

  test 'global listing renders boosted slot once on the first page' do
    covers 'events/boosted-slot@240568'
    create_event(as: :event1, name: 'Spotlight listing event', prices: [0])
    create_event(as: :event2, name: 'Regular listing event', prices: [0])

    FactoryBot.create(:event_boost,
                      event: @event1,
                      account: @account,
                      start_time: Time.zone.now.beginning_of_hour,
                      hours: 2,
                      hourly_amount: 10)

    visit "/events?organisation_id=#{@organisation.id}"

    assert page.has_content?('Boosted by')
    assert_equal 1, page.text.scan('Spotlight listing event').length
    assert page.has_content?('Regular listing event')
    assert_equal 1, @event1.event_boost_impressions.count

    visit "/events?organisation_id=#{@organisation.id}&page=2"
    # Page 2 is empty, so wait for the list's placeholder to be replaced before looking for the slot
    assert page.has_no_css?('#events .placeholder')
    assert page.has_no_content?('Boosted by')
  end

  test 'public listing ignores incomplete active boosts' do
    account = FactoryBot.create(:account)
    organisation1 = FactoryBot.create(:organisation, account: account, name: 'Visible Org')
    organisation2 = FactoryBot.create(:organisation, account: account, name: 'Other Org')
    event1 = FactoryBot.create(:event, organisation: organisation1, name: 'Org one event', prices: [0])
    FactoryBot.create(:event, organisation: organisation2, name: 'Org two event', prices: [0])

    FactoryBot.create(:event_boost, :pending_payment,
                      event: event1,
                      account: account,
                      start_time: Time.zone.now.beginning_of_hour,
                      hours: 1,
                      hourly_amount: EventBoost.minimum_hourly_amount(event1.currency_or_default))

    visit '/events'

    assert page.has_content?('Org one event')
    assert page.has_content?('Org two event')
    assert page.has_no_content?('Boosted')
  end

  test 'boost slot is not shown on homepage teasers or minimal embeds' do
    create_event(name: 'Hidden boost slot event', prices: [0])
    @event.set(has_image: true)

    FactoryBot.create(:event_boost,
                      event: @event,
                      account: @account,
                      start_time: Time.zone.now.beginning_of_hour,
                      hours: 1,
                      hourly_amount: 10)
    assert_includes EventBoost.active_at.pluck(:event_id), @event.id

    visit '/events?home=1&images=1&order=trending'
    assert page.has_content?('Hidden boost slot event')
    assert page.has_no_content?('Boosted')

    visit "/o/#{@organisation.slug}/events?minimal=1"
    assert page.has_content?('Hidden boost slot event')
    assert page.has_no_content?('Boosted')
  end

  test 'boosted unpaid event appears in the boost slot but not the regular listing' do
    covers 'events/boosted-slot@240568'
    covers_route 'GET /events'
    create_organisation
    @organisation.set(paid_up: false)
    create_event(name: 'Promotion-only boosted event')
    @event.set_browsable
    refute @event.reload.browsable?

    FactoryBot.create(:event_boost,
                      event: @event,
                      account: @account,
                      start_time: Time.zone.now.beginning_of_hour,
                      hours: 2,
                      hourly_amount: 10)

    visit "/events?organisation_id=#{@organisation.id}"

    assert page.has_content?('Boosted by')
    assert page.has_content?('Promotion-only boosted event')
    assert_equal 1, page.text.scan('Promotion-only boosted event').length
    assert_equal 1, @event.event_boost_impressions.count
  end

  test 'boosts are bought in whole-hour blocks' do
    covers 'events/boost-whole-hours@2913d6'
    create_event(prices: [0])
    start_time = Time.zone.now.beginning_of_hour + 2.hours

    boost = FactoryBot.build(:event_boost, event: @event, start_time: start_time + 30.minutes, hours: 1)
    refute boost.valid?
    assert_includes boost.errors[:start_time], 'must be on the hour'

    boost = FactoryBot.build(:event_boost, event: @event, start_time: start_time, hours: 1.5)
    refute boost.valid?
    assert boost.errors[:hours].any?

    boost = FactoryBot.create(:event_boost, event: @event, start_time: start_time, hours: 3, hourly_amount: 2)
    assert_equal start_time + 3.hours, boost.end_time
    assert_in_delta 6.0, boost.total_amount
  end

  test 'overlapping boosts for the same event stack together' do
    covers 'events/boosts-stack@705d4b'
    create_event(prices: [0])
    start_time = Time.zone.now.beginning_of_hour
    FactoryBot.create(:event_boost, event: @event, start_time: start_time, hours: 3, hourly_amount: 2)
    FactoryBot.create(:event_boost, event: @event, start_time: start_time + 1.hour, hours: 1, hourly_amount: 3)

    assert_equal({ @event.id => 200 }, EventBoost.active_hourly_weights_by_event_id([@event.id], time: start_time + 30.minutes))
    assert_equal({ @event.id => 500 }, EventBoost.active_hourly_weights_by_event_id([@event.id], time: start_time + 90.minutes))
    assert_equal({ @event.id => 200 }, EventBoost.active_hourly_weights_by_event_id([@event.id], time: start_time + 150.minutes))
  end

  test "an event's chance of the boost slot is its share of the boost pool, and higher in filtered listings" do
    covers 'events/boost-pool-share@a0d853', 'events/boost-example-unfiltered@c7b401', 'events/boost-example-filtered@b5d026', 'events/boost-example-filtered-rave@3f664d'
    create_event(as: :event1, name: 'Breathwork Journey', prices: [0])
    create_event(as: :event2, name: 'Day Rave', prices: [0])
    breathwork = FactoryBot.create(:event_tag, name: 'breathwork')
    rave = FactoryBot.create(:event_tag, name: 'rave')
    @event1.event_tagships.create!(event_tag: breathwork)
    @event2.event_tagships.create!(event_tag: rave)
    start_time = Time.zone.now.beginning_of_hour
    FactoryBot.create(:event_boost, event: @event1, start_time: start_time, hours: 2, hourly_amount: 2)
    FactoryBot.create(:event_boost, event: @event2, start_time: start_time, hours: 2, hourly_amount: 8)

    # Each draw of the pool, in pence: £2 + £8 = 1000
    picks = (0...1000).map do |draw|
      EventBoost.pick_event_for_scope(Event.live.publicly_visible.future, rng: Struct.new(:draw) { def rand(_) = draw }.new(draw))&.name
    end
    assert_equal({ 'Breathwork Journey' => 200, 'Day Rave' => 800 }, picks.tally)
    assert_in_delta 0.2, EventBoost.pool_hour_stats(@event1, slot_start: start_time)[:share]

    xhr = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
    3.times { get '/events', { event_tag_id: breathwork.id }, xhr }
    assert_equal 3, @event1.event_boost_impressions.count
    3.times { get '/events', { event_tag_id: rave.id }, xhr }
    assert_equal 3, @event2.event_boost_impressions.count
    assert_equal 3, @event1.event_boost_impressions.count
  end

  def boost_params(hourly_amount:)
    {
      start_time: (Time.zone.now.beginning_of_hour + 2.hours).strftime('%Y-%m-%d %H:%M'),
      hours: 1,
      hourly_amount: hourly_amount,
      currency: @event.currency_or_default
    }
  end

  test 'a boost that fails its checks answers with the error, saving nothing and starting no checkout' do
    create_event(prices: [0])
    sign_in_with_rack(@account)
    minimum = EventBoost.minimum_hourly_amount(@event.currency_or_default)

    Stripe::Checkout::Session.stub :create, ->(*) { raise 'no checkout should be started' } do
      post "/e/#{@event.slug}/boosts", event_boost: boost_params(hourly_amount: minimum * 0.9)
    end
    assert_equal 400, last_response.status
    assert_match(/\AHourly amount must be at least /, JSON.parse(last_response.body)['error'])
    assert_equal 0, @event.event_boosts.count

    Stripe::Checkout::Session.stub :create, api_object(id: 'cs_boost', payment_intent: 'pi_boost') do
      post "/e/#{@event.slug}/boosts", event_boost: boost_params(hourly_amount: minimum)
    end
    assert_equal 200, last_response.status
    assert_equal 'cs_boost', JSON.parse(last_response.body)['session_id']
    assert_equal ['cs_boost'], @event.event_boosts.pluck(:session_id)
  end

  test 'a boost whose Stripe checkout cannot be started is removed again' do
    create_event(prices: [0])
    sign_in_with_rack(@account)
    minimum = EventBoost.minimum_hourly_amount(@event.currency_or_default)
    attempted = false

    Stripe::Checkout::Session.stub :create, lambda { |*|
      attempted = true
      raise Stripe::APIConnectionError, 'Stripe is unreachable'
    } do
      post "/e/#{@event.slug}/boosts", event_boost: boost_params(hourly_amount: minimum)
    end
    assert attempted, 'the boost never reached Stripe'
    assert_equal 400, last_response.status
    assert_equal 'There was an error creating the boost.', JSON.parse(last_response.body)['error']
    assert_equal 0, @event.event_boosts.count

    Stripe::Checkout::Session.stub :create, api_object(id: 'cs_boost', payment_intent: 'pi_boost') do
      post "/e/#{@event.slug}/boosts", event_boost: boost_params(hourly_amount: minimum)
    end
    assert_equal 200, last_response.status
    assert_equal 1, @event.event_boosts.count
  end

  test "a boost can't be bought for an event that's locked or secret, or to start before this hour, and nothing is made" do
    create_event(prices: [0])
    sign_in_with_rack(@account)
    this_hour = Time.zone.now.beginning_of_hour
    buy = lambda do |start_time|
      post "/e/#{@event.slug}/boosts", event_boost: { start_time: start_time.strftime('%Y-%m-%d %H:%M'), hours: 1, hourly_amount: 10, currency: @event.currency_or_default }
    end

    @event.set(locked: true)
    buy.call(this_hour + 1.hour)
    assert_equal 400, last_response.status
    assert_equal 'Event must be live', JSON.parse(last_response.body)['error']
    @event.set(locked: false, secret: true)
    buy.call(this_hour + 1.hour)
    assert_equal 400, last_response.status
    assert_equal 'Event must be publicly visible', JSON.parse(last_response.body)['error']
    @event.set(secret: false)
    buy.call(this_hour - 1.hour)
    assert_equal 400, last_response.status
    assert_equal 'Start time must be this hour or later', JSON.parse(last_response.body)['error']
    assert_equal 0, @event.event_boosts.count

    Stripe::Checkout::Session.stub :create, api_object(id: 'cs_this_hour', payment_intent: 'pi_test') do
      buy.call(this_hour)
    end
    assert last_response.ok?
    assert_equal 'cs_this_hour', JSON.parse(last_response.body)['session_id']
    assert_equal [this_hour], @event.event_boosts.pluck(:start_time)
  end
end
