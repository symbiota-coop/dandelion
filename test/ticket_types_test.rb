require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class TicketTypesTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'parses fixed price from price_or_range' do
    event = FactoryBot.build(:event)
    ticket_type = TicketType.new(event: event, price_or_range: '25', price_or_range_submitted: true, name: 'Standard', quantity: 10)

    assert ticket_type.valid?, ticket_type.errors.full_messages.join(', ')
    assert_equal 25.0, ticket_type.price
    assert_nil ticket_type.range_min
    assert_nil ticket_type.range_max
  end

  test 'parses price range from price_or_range' do
    event = FactoryBot.build(:event)
    ticket_type = TicketType.new(event: event, price_or_range: '10-100', price_or_range_submitted: true, name: 'Sliding scale', quantity: 10)

    assert ticket_type.valid?, ticket_type.errors.full_messages.join(', ')
    assert_nil ticket_type.price
    assert_equal 10.0, ticket_type.range_min
    assert_equal 100.0, ticket_type.range_max
    assert_equal '10-100', ticket_type.price_or_range
  end

  test 'remaining excludes tickets made available again' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 2)
    ticket_type.tickets.create!(event: @event, payment_completed: true)
    ticket_type.tickets.create!(event: @event, payment_completed: true, made_available_at: Time.now)

    assert_equal 1, ticket_type.remaining
    assert_equal 0, ticket_type.remaining_including_made_available
  end

  test 'sold_out? when quantity is exhausted' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 1)
    ticket_type.tickets.create!(event: @event, payment_completed: true)

    assert ticket_type.sold_out?
    refute ticket_type.tickets_available?
  end

  test 'updates existing ticket type via nested attributes' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first

    assert @event.update_attributes(ticket_types_attributes: {
                                      '0' => {
                                        'id' => ticket_type.id.to_s,
                                        'name' => 'Updated pass',
                                        'quantity' => 5,
                                        'price' => 0
                                      }
                                    })

    ticket_type.reload
    assert_equal 'Updated pass', ticket_type.name
    assert_equal 5, ticket_type.quantity
  end

  test 'accepts slots via nested attributes' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first

    assert @event.update_attributes(ticket_types_attributes: {
                                      '0' => {
                                        'id' => ticket_type.id.to_s,
                                        'name' => ticket_type.name,
                                        'quantity' => ticket_type.quantity,
                                        'slots' => 2
                                      }
                                    })

    assert_equal 2, ticket_type.reload.slots
  end

  test 'destroys existing ticket type via nested attributes' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first

    assert @event.update_attributes(ticket_types_attributes: {
                                      '0' => { 'id' => ticket_type.id.to_s, '_destroy' => '1' }
                                    })

    refute TicketType.and(id: ticket_type.id).exists?
  end

  test 'ignores nested attributes for missing ticket type id' do
    create_event(prices: [0])
    original_count = @event.ticket_types.count
    stale_id = BSON::ObjectId.new

    assert @event.update_attributes(ticket_types_attributes: {
                                      '0' => {
                                        'id' => stale_id.to_s,
                                        'name' => 'Ghost pass',
                                        'quantity' => 1,
                                        'price' => 0
                                      }
                                    })

    assert_equal original_count, @event.reload.ticket_types.count
    refute @event.ticket_types.and(id: stale_id).exists?
  end

  test 'rejects nested destroy when id is not on event regardless of _destroy flag' do
    create_event(as: :event1, prices: [0])
    create_event(as: :event2, prices: [0])
    other_ticket_type = @event2.ticket_types.first
    attributes = {
      'id' => other_ticket_type.id.to_s,
      '_destroy' => '1'
    }

    assert @event1.reject_ticket_type_nested_attributes?(attributes),
           'reject_if must not skip association check just because _destroy is present'
    assert @event1.update_attributes(ticket_types_attributes: { '0' => attributes })
    assert TicketType.and(id: other_ticket_type.id).exists?,
           'ticket type from another event must not be destroyed'
  end

  test 'ignores nested attributes for ticket type from another event' do
    create_event(as: :event1, prices: [0])
    create_event(as: :event2, prices: [0])
    other_ticket_type = @event2.ticket_types.first

    assert @event1.update_attributes(ticket_types_attributes: {
                                       '0' => {
                                         'id' => other_ticket_type.id.to_s,
                                         'name' => 'Hijacked pass',
                                         'quantity' => 1,
                                         'price' => 0
                                       }
                                     })

    refute @event1.reload.ticket_types.and(id: other_ticket_type.id).exists?
    refute_equal 'Hijacked pass', other_ticket_type.reload.name
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Slots
  # ═══════════════════════════════════════════════════════════════════════════

  test 'nil slots is saved as 1' do
    create_event(prices: [0], capacity: 10)
    ticket_type = @event.ticket_types.first
    ticket_type.quantity = 10
    ticket_type.slots = nil

    assert ticket_type.save!
    assert_equal 1, ticket_type.reload.slots
    assert_equal 10, ticket_type.number_of_tickets_available_in_single_purchase
  end

  test 'rejects negative slots' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.slots = -1

    refute ticket_type.valid?
    assert_includes ticket_type.errors[:slots], 'must not be < 0'
  end

  test 'event places remaining uses slots rather than ticket count' do
    create_event(prices: [0], capacity: 10)
    ticket_type = @event.ticket_types.first
    ticket_type.set(slots: 2, quantity: 10)
    ticket_type.tickets.create!(event: @event, payment_completed: true)
    ticket_type.tickets.create!(event: @event, payment_completed: true, made_available_at: Time.now)

    assert_equal 8, @event.places_remaining
    assert_equal 2, @event.slots_taken
  end

  test 'add-on tickets with 0 slots do not reduce event capacity' do
    create_event(prices: [0], capacity: 1)
    main = @event.ticket_types.first
    main.set(quantity: 10, slots: 1)
    addon = FactoryBot.create(:ticket_type, event: @event, quantity: 10, slots: 0)

    main.tickets.create!(event: @event, payment_completed: true)
    addon.tickets.create!(event: @event, payment_completed: true)

    assert_equal 1, @event.slots_taken
    assert_equal 0, @event.places_remaining
    assert main.reload.sold_out?
    refute addon.reload.sold_out?
    assert_equal 9, addon.number_of_tickets_available_in_single_purchase
  end

  test 'couples tickets take two places from event capacity' do
    create_event(prices: [0], capacity: 3)
    ticket_type = @event.ticket_types.first
    ticket_type.set(slots: 2, quantity: 10)

    assert_equal 1, ticket_type.number_of_tickets_available_in_single_purchase

    ticket_type.tickets.create!(event: @event, payment_completed: true)

    assert_equal 1, @event.places_remaining
    assert_equal 0, ticket_type.reload.number_of_tickets_available_in_single_purchase
    assert ticket_type.sold_out?
  end

  test 'ticket group places remaining uses slots' do
    create_event(prices: [0])
    ticket_group = @event.ticket_groups.create!(name: 'Saturday', capacity: 3)
    ticket_type = @event.ticket_types.first
    ticket_type.set(ticket_group_id: ticket_group.id, slots: 2, quantity: 10)

    assert_equal 1, ticket_type.number_of_tickets_available_in_single_purchase

    ticket_type.tickets.create!(event: @event, payment_completed: true)

    assert_equal 1, ticket_group.places_remaining
    assert_equal 2, ticket_group.slots_taken
    assert_equal 0, ticket_type.reload.number_of_tickets_available_in_single_purchase
  end

  test 'add-on tickets with 0 slots do not reduce ticket group capacity' do
    create_event(prices: [0])
    ticket_group = @event.ticket_groups.create!(name: 'Saturday', capacity: 1)
    main = @event.ticket_types.first
    main.set(ticket_group_id: ticket_group.id, quantity: 10, slots: 1)
    addon = FactoryBot.create(:ticket_type, event: @event, ticket_group: ticket_group, quantity: 10, slots: 0)

    main.tickets.create!(event: @event, payment_completed: true)
    addon.tickets.create!(event: @event, payment_completed: true)

    assert_equal 1, ticket_group.slots_taken
    assert_equal 0, ticket_group.places_remaining
    assert main.reload.sold_out?
    refute addon.reload.sold_out?
  end

  test 'duplicating an event copies ticket type slots' do
    create_event(prices: [0])
    @event.ticket_types.first.set(slots: 2)

    duplicate = @event.duplicate!(@account)

    assert_equal 2, duplicate.ticket_types.first.slots
  end
end

