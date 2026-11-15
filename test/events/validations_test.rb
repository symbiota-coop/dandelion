require_relative '../test_config'
require_relative '../helpers/organisations_helpers'

# The event's validations that guard money: who its revenue goes to and in what shares, its suggested donation, and
# its times. Called on the model, as nobody is on the other end
class EventValidationsTest < ActiveSupport::TestCase
  include OrganisationsHelpers

  def refused(event, attribute, message)
    refute event.valid?
    assert_includes event.errors[attribute], message
  end

  test 'the revenue sharer and their share can change until the event has orders, and not after' do
    create_event
    sharer = connected_account(@organisation)
    other_sharer = connected_account(@organisation)
    @event.update!(revenue_sharer: sharer, revenue_share_to_revenue_sharer: 10)
    @event.update!(revenue_sharer: other_sharer, revenue_share_to_revenue_sharer: 20)
    assert_equal([other_sharer.id, 20], Event.find(@event.id).then { |event| [event.revenue_sharer_id, event.revenue_share_to_revenue_sharer] })

    @event.orders.create!(account: FactoryBot.create(:account), currency: @event.currency, value: 0, payment_completed: true)

    event = Event.find(@event.id)
    event.revenue_sharer = sharer
    refute event.save
    assert_equal ['cannot be changed as the event has orders'], event.errors[:revenue_sharer]
    assert_empty event.errors[:revenue_share_to_revenue_sharer]

    event = Event.find(@event.id)
    event.revenue_share_to_revenue_sharer = 30
    refute event.save
    assert_equal ['cannot be changed as the event has orders'], event.errors[:revenue_share_to_revenue_sharer]
    assert_empty event.errors[:revenue_sharer]

    assert_equal([other_sharer.id, 20], Event.find(@event.id).then { |event| [event.revenue_sharer_id, event.revenue_share_to_revenue_sharer] })
    # Other settings can still change
    assert Event.find(@event.id).update(name: 'Renamed')
  end

  # Every event has a creator (validates_presence_of :account), so the event's own 'or revenue sharer must be set'
  # error can't be reached: an organiser left blank is the creator
  test "a Stripe Connect organisation's events with no revenue sharer have the event's creator as organiser" do
    create_organisation(stripe_client_id: 'ca_test')
    create_event(organiser: nil)
    assert_equal @account.id, @event.organiser_id

    event = Event.find(@event.id)
    event.organiser = nil
    assert event.save, event.errors.full_messages.to_sentence
    assert_equal @account.id, Event.find(@event.id).organiser_id

    # A revenue sharer stands in for the organiser
    event = Event.find(@event.id)
    event.assign_attributes(organiser: nil, revenue_sharer: connected_account(@organisation), revenue_share_to_revenue_sharer: 10)
    assert event.save, event.errors.full_messages.to_sentence
    assert_nil Event.find(@event.id).organiser_id

    # Without Stripe Connect, a blank organiser stays blank
    @organisation.set(stripe_client_id: nil)
    event = Event.find(@event.id)
    event.assign_attributes(revenue_sharer: nil)
    assert event.save, event.errors.full_messages.to_sentence
    assert_nil Event.find(@event.id).organiser_id
  end

  test 'an organisation can require each event to have an organiser or a revenue sharer' do
    create_organisation(require_organiser_or_revenue_sharer: true)
    create_event(organiser: FactoryBot.create(:account))

    event = Event.find(@event.id)
    event.organiser = nil
    refused(event, :revenue_sharer, 'or organiser must be set for this organisation')
    refute Event.find(@event.id).organiser_id.nil?

    event.revenue_sharer = connected_account(@organisation)
    event.revenue_share_to_revenue_sharer = 10
    assert event.valid?, event.errors.full_messages.to_sentence

    @organisation.set(require_organiser_or_revenue_sharer: false)
    event = Event.find(@event.id)
    event.organiser = nil
    assert event.valid?, event.errors.full_messages.to_sentence
  end

  test "an event can't have both an organiser and a revenue sharer" do
    create_event
    event = Event.find(@event.id)
    event.revenue_sharer = connected_account(@organisation)
    event.revenue_share_to_revenue_sharer = 10
    event.organiser = FactoryBot.create(:account)
    refused(event, :revenue_sharer, 'cannot be set if organiser is set')

    event.organiser = nil
    assert event.valid?, event.errors.full_messages.to_sentence
  end

  test "the revenue sharer must have connected their Stripe account to the event's organisation" do
    create_event
    unconnected = FactoryBot.create(:account)
    # A member who hasn't connected Stripe isn't connected either
    unconnected.organisationships.create!(organisation: @organisation)
    other_organisation = FactoryBot.create(:organisation)
    connected_elsewhere = FactoryBot.create(:account)
    connected_elsewhere.organisationships.create!(organisation: other_organisation, stripe_connect_json: { 'stripe_user_id' => 'acct_elsewhere' }.to_json)

    [unconnected, connected_elsewhere].each do |sharer|
      refused(Event.find(@event.id).tap { |event| event.assign_attributes(revenue_sharer: sharer, revenue_share_to_revenue_sharer: 10) },
              :revenue_sharer, 'is not connected to this organisation')
    end
    assert_nil Event.find(@event.id).revenue_sharer_id

    assert Event.find(@event.id).update(revenue_sharer: connected_account(@organisation), revenue_share_to_revenue_sharer: 10)
  end

  test "the revenue sharer's share is between 1 and 100" do
    create_event
    sharer = connected_account(@organisation)

    [-5, 101].each do |share|
      event = Event.find(@event.id)
      event.assign_attributes(revenue_sharer: sharer, revenue_share_to_revenue_sharer: share)
      refused(event, :revenue_share_to_revenue_sharer, 'must be between 1 and 100')
    end
    [1, 100].each do |share|
      event = Event.find(@event.id)
      event.assign_attributes(revenue_sharer: sharer, revenue_share_to_revenue_sharer: share)
      assert event.valid?, event.errors.full_messages.to_sentence
    end
  end

  test "each profit share is between 0% and 100%, and together they're no more than the organisation's share of the revenue" do
    create_event

    [-1, 101].each do |share|
      refused(Event.find(@event.id).tap { |event| event.profit_share_to_coordinator = share }, :profit_share_to_coordinator, 'must be between 0% and 100%')
    end

    event = Event.find(@event.id)
    event.assign_attributes(profit_share_to_organiser: 60, profit_share_to_coordinator: 41)
    refused(event, :profit_share_to_coordinator, 'along with other profit shares must not be greater than 100%')
    assert_includes event.errors[:profit_share_to_organiser], 'along with other profit shares must not be greater than 100%'
    event.profit_share_to_coordinator = 40
    assert event.valid?, event.errors.full_messages.to_sentence

    # A revenue sharer's share leaves the organisation less to share out, and the organiser none (it's set to 0)
    event = Event.find(@event.id)
    event.assign_attributes(revenue_sharer: connected_account(@organisation), revenue_share_to_revenue_sharer: 20, profit_share_to_coordinator: 81)
    refused(event, :profit_share_to_coordinator, 'along with other profit shares must not be greater than 80%')
    event.profit_share_to_coordinator = 80
    assert event.valid?, event.errors.full_messages.to_sentence
  end

  test 'the suggested donation is not below the minimum donation' do
    create_event
    assert @organisation.payment_method?

    event = Event.find(@event.id)
    event.assign_attributes(suggested_donation: 4.99, minimum_donation: 5)
    refused(event, :suggested_donation, 'cannot be less than the minimum donation')

    event.suggested_donation = 5
    assert event.save, event.errors.full_messages.to_sentence
    assert_equal([5, 5], Event.find(@event.id).then { |e| [e.suggested_donation, e.minimum_donation] })
  end

  test 'an event ends after it starts, and asks for feedback no sooner than it ends' do
    create_event
    start_time = @event.start_time

    [start_time, start_time - 1.hour].each do |end_time|
      refused(Event.find(@event.id).tap { |event| event.end_time = end_time }, :end_time, 'must be after the start time')
    end
    assert Event.find(@event.id).tap { |event| event.end_time = start_time + 1.minute }.valid?

    refused(Event.find(@event.id).tap { |event| event.feedback_hours_after = -1 }, :feedback_hours_after, 'cannot be negative')
    assert Event.find(@event.id).update(feedback_hours_after: 0)
    assert_equal 0, Event.find(@event.id).feedback_hours_after
  end

  test "an event's tax rate starts with txr_" do
    create_event
    ['tax_123', 'TXR_123', '123'].each do |tax_rate_id|
      refused(Event.find(@event.id).tap { |event| event.tax_rate_id = tax_rate_id }, :tax_rate_id, 'must start with txr_')
    end
    assert_nil Event.find(@event.id).tax_rate_id

    assert Event.find(@event.id).update(tax_rate_id: 'txr_123')
    assert_equal 'txr_123', Event.find(@event.id).tax_rate_id
  end

  test "an event's Open Collective slug can't be set until its organisation's is" do
    create_event
    refused(Event.find(@event.id).tap { |event| event.oc_slug = 'agm-2026' }, :oc_slug, "cannot be set until the organisation's Open Collective slug is set")
    assert_nil Event.find(@event.id).oc_slug

    @organisation.set(oc_slug: 'grain-network')
    assert Event.find(@event.id).update(oc_slug: 'agm-2026')
    assert_equal 'agm-2026', Event.find(@event.id).oc_slug
  end

  test "an event's sessions start no earlier than the event and end no later, each after it starts" do
    create_event
    start_time = @event.start_time
    end_time = @event.end_time
    session = ->(starts, ends) { @event.event_sessions.new(start_time: starts, end_time: ends) }

    refused(session.call(start_time - 1.minute, start_time + 1.hour), :start_time, 'must be after event start time')
    refused(session.call(end_time - 1.hour, end_time + 1.minute), :end_time, 'must be before event end time')
    [start_time + 1.hour, start_time + 30.minutes].each do |ends|
      refused(session.call(start_time + 1.hour, ends), :end_time, 'must be after the start time')
    end
    assert_equal 0, EventSession.count

    # From the event's very start to its very end
    session.call(start_time, end_time).save!
    session.call(start_time + 1.hour, start_time + 1.hour + 1.minute).save!
    assert_equal 2, @event.event_sessions.count
  end
end
