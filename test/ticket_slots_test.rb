require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class TicketSlotsTest < ActiveSupport::TestCase
  def create_event(**attrs)
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, **attrs)
  end

  test 'nil slots is saved as 1' do
    event = create_event(prices: [0], capacity: 10)
    ticket_type = event.ticket_types.first
    ticket_type.quantity = 10
    ticket_type.slots = nil

    assert ticket_type.save!
    assert_equal 1, ticket_type.reload.slots
    assert_equal 10, ticket_type.number_of_tickets_available_in_single_purchase
  end

  test 'rejects negative slots' do
    event = create_event(prices: [0])
    ticket_type = event.ticket_types.first
    ticket_type.slots = -1

    refute ticket_type.valid?
    assert_includes ticket_type.errors[:slots], 'must not be < 0'
  end

  test 'event places remaining uses slots rather than ticket count' do
    event = create_event(prices: [0], capacity: 10)
    ticket_type = event.ticket_types.first
    ticket_type.set(slots: 2, quantity: 10)
    ticket_type.tickets.create!(event: event, payment_completed: true)
    ticket_type.tickets.create!(event: event, payment_completed: true, made_available_at: Time.now)

    assert_equal 8, event.places_remaining
    assert_equal 2, event.slots_taken
  end

  test 'add-on tickets with 0 slots do not reduce event capacity' do
    event = create_event(prices: [0], capacity: 1)
    main = event.ticket_types.first
    main.set(quantity: 10, slots: 1)
    addon = FactoryBot.create(:ticket_type, event: event, quantity: 10, slots: 0)

    main.tickets.create!(event: event, payment_completed: true)
    addon.tickets.create!(event: event, payment_completed: true)

    assert_equal 1, event.slots_taken
    assert_equal 0, event.places_remaining
    assert main.reload.sold_out?
    refute addon.reload.sold_out?
    assert_equal 9, addon.number_of_tickets_available_in_single_purchase
  end

  test 'couples tickets take two places from event capacity' do
    event = create_event(prices: [0], capacity: 3)
    ticket_type = event.ticket_types.first
    ticket_type.set(slots: 2, quantity: 10)

    assert_equal 1, ticket_type.number_of_tickets_available_in_single_purchase

    ticket_type.tickets.create!(event: event, payment_completed: true)

    assert_equal 1, event.places_remaining
    assert_equal 0, ticket_type.reload.number_of_tickets_available_in_single_purchase
    assert ticket_type.sold_out?
  end

  test 'ticket group places remaining uses slots' do
    event = create_event(prices: [0])
    ticket_group = event.ticket_groups.create!(name: 'Saturday', capacity: 3)
    ticket_type = event.ticket_types.first
    ticket_type.set(ticket_group_id: ticket_group.id, slots: 2, quantity: 10)

    assert_equal 1, ticket_type.number_of_tickets_available_in_single_purchase

    ticket_type.tickets.create!(event: event, payment_completed: true)

    assert_equal 1, ticket_group.places_remaining
    assert_equal 2, ticket_group.slots_taken
    assert_equal 0, ticket_type.reload.number_of_tickets_available_in_single_purchase
  end

  test 'add-on tickets with 0 slots do not reduce ticket group capacity' do
    event = create_event(prices: [0])
    ticket_group = event.ticket_groups.create!(name: 'Saturday', capacity: 1)
    main = event.ticket_types.first
    main.set(ticket_group_id: ticket_group.id, quantity: 10, slots: 1)
    addon = FactoryBot.create(:ticket_type, event: event, ticket_group: ticket_group, quantity: 10, slots: 0)

    main.tickets.create!(event: event, payment_completed: true)
    addon.tickets.create!(event: event, payment_completed: true)

    assert_equal 1, ticket_group.slots_taken
    assert_equal 0, ticket_group.places_remaining
    assert main.reload.sold_out?
    refute addon.reload.sold_out?
  end

  test 'duplicating an event copies ticket type slots' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    event = FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, prices: [0])
    event.ticket_types.first.set(slots: 2)

    duplicate = event.duplicate!(account)

    assert_equal 2, duplicate.ticket_types.first.slots
  end
end
