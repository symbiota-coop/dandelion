require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class TicketTypesTest < ActiveSupport::TestCase
  include Capybara::DSL

  def create_event(**attrs)
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, **attrs)
  end

  test 'requires name and quantity' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    event = FactoryBot.build(:event, organisation: organisation, account: account, last_saved_by: account)
    ticket_type = TicketType.new(event: event)

    refute ticket_type.valid?
    assert_includes ticket_type.errors[:name], "can't be blank"
    assert_includes ticket_type.errors[:quantity], "can't be blank"
  end

  test 'parses fixed price from price_or_range' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    event = FactoryBot.build(:event, organisation: organisation, account: account, last_saved_by: account)
    ticket_type = TicketType.new(event: event, price_or_range: '25', price_or_range_submitted: true, name: 'Standard', quantity: 10)

    assert ticket_type.valid?, ticket_type.errors.full_messages.join(', ')
    assert_equal 25.0, ticket_type.price
    assert_nil ticket_type.range_min
    assert_nil ticket_type.range_max
  end

  test 'parses price range from price_or_range' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    event = FactoryBot.build(:event, organisation: organisation, account: account, last_saved_by: account)
    ticket_type = TicketType.new(event: event, price_or_range: '10-100', price_or_range_submitted: true, name: 'Sliding scale', quantity: 10)

    assert ticket_type.valid?, ticket_type.errors.full_messages.join(', ')
    assert_nil ticket_type.price
    assert_equal 10.0, ticket_type.range_min
    assert_equal 100.0, ticket_type.range_max
    assert_equal '10-100', ticket_type.price_or_range
  end

  test 'remaining excludes tickets made available again' do
    event = create_event(prices: [0])
    ticket_type = event.ticket_types.first
    ticket_type.set(quantity: 2)
    ticket_type.tickets.create!(event: event, payment_completed: true)
    ticket_type.tickets.create!(event: event, payment_completed: true, made_available_at: Time.now)

    assert_equal 1, ticket_type.remaining
    assert_equal 0, ticket_type.remaining_including_made_available
  end

  test 'sold_out? when quantity is exhausted' do
    event = create_event(prices: [0])
    ticket_type = event.ticket_types.first
    ticket_type.set(quantity: 1)
    ticket_type.tickets.create!(event: event, payment_completed: true)

    assert ticket_type.sold_out?
    refute ticket_type.tickets_available?
  end

  test 'rejects blank nested ticket type attributes' do
    event = create_event

    assert event.reject_ticket_type_nested_attributes?({})
    assert event.reject_ticket_type_nested_attributes?('name' => nil, 'description' => nil, 'price' => nil, 'quantity' => nil)
  end

  test 'accepts new ticket type via nested attributes' do
    event = create_event

    assert event.update_attributes(ticket_types_attributes: {
                                     '0' => { 'name' => 'VIP', 'quantity' => 10, 'price' => 25 }
                                   })
    ticket_type = event.ticket_types.find_by(name: 'VIP')

    assert ticket_type
    assert_equal 10, ticket_type.quantity
    assert_equal 25.0, ticket_type.price
  end

  test 'updates existing ticket type via nested attributes' do
    event = create_event(prices: [0])
    ticket_type = event.ticket_types.first

    assert event.update_attributes(ticket_types_attributes: {
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

  test 'destroys existing ticket type via nested attributes' do
    event = create_event(prices: [0])
    ticket_type = event.ticket_types.first

    assert event.update_attributes(ticket_types_attributes: {
                                     '0' => { 'id' => ticket_type.id.to_s, '_destroy' => '1' }
                                   })

    refute TicketType.and(id: ticket_type.id).exists?
  end

  test 'ignores nested attributes for missing ticket type id' do
    event = create_event(prices: [0])
    original_count = event.ticket_types.count
    stale_id = BSON::ObjectId.new

    assert event.update_attributes(ticket_types_attributes: {
                                     '0' => {
                                       'id' => stale_id.to_s,
                                       'name' => 'Ghost pass',
                                       'quantity' => 1,
                                       'price' => 0
                                     }
                                   })

    assert_equal original_count, event.reload.ticket_types.count
    refute event.ticket_types.and(id: stale_id).exists?
  end

  test 'ignores nested destroy for already deleted ticket type' do
    event = create_event(prices: [0])
    ticket_type = event.ticket_types.first
    ticket_type_id = ticket_type.id.to_s
    ticket_type.destroy

    assert event.update_attributes(ticket_types_attributes: {
                                     '0' => {
                                       'id' => ticket_type_id,
                                       '_destroy' => '1',
                                       'name' => 'Gone pass',
                                       'quantity' => 1
                                     }
                                   })
  end

  test 'rejects nested destroy when id is not on event regardless of _destroy flag' do
    event = create_event(prices: [0])
    other_event = create_event(prices: [0])
    other_ticket_type = other_event.ticket_types.first
    attributes = {
      'id' => other_ticket_type.id.to_s,
      '_destroy' => '1'
    }

    assert event.reject_ticket_type_nested_attributes?(attributes),
           'reject_if must not skip association check just because _destroy is present'
    assert event.update_attributes(ticket_types_attributes: { '0' => attributes })
    assert TicketType.and(id: other_ticket_type.id).exists?,
           'ticket type from another event must not be destroyed'
  end

  test 'ignores nested attributes for ticket type from another event' do
    event = create_event(prices: [0])
    other_event = create_event(prices: [0])
    other_ticket_type = other_event.ticket_types.first

    assert event.update_attributes(ticket_types_attributes: {
                                     '0' => {
                                       'id' => other_ticket_type.id.to_s,
                                       'name' => 'Hijacked pass',
                                       'quantity' => 1,
                                       'price' => 0
                                     }
                                   })

    refute event.reload.ticket_types.and(id: other_ticket_type.id).exists?
    refute_equal 'Hijacked pass', other_ticket_type.reload.name
  end
end
