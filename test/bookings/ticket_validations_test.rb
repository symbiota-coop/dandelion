require_relative '../test_config'

# What a ticket type may be set to, and the ticket's own refusals of a sale its type can't make: the booking flow
# checks these first, so these are the backstops, tested on the models
class BookingsTicketValidationsTest < ActiveSupport::TestCase
  def create_ticket_type(**attrs)
    create_event
    @event.ticket_types.create!(name: 'Standard', price_or_range_submitted: true, price_or_range: 10, quantity: 2, **attrs)
  end

  # A new ticket of ticket_type, read fresh so its counts include the tickets saved so far
  def new_ticket(ticket_type, account: FactoryBot.create(:account), **attrs)
    Ticket.new(event: Event.find(@event.id), account: account, ticket_type: TicketType.find(ticket_type.id), **attrs)
  end

  def assert_ticket_refused(ticket, message)
    refute ticket.save
    assert_equal [message], ticket.errors[:ticket_type]
  end

  test 'a ticket of a full ticket type is refused, unless complimentary' do
    ticket_type = create_ticket_type(quantity: 1)
    assert new_ticket(ticket_type).save
    assert_equal 1, @event.tickets.count

    assert_ticket_refused new_ticket(ticket_type), 'is full'
    assert_equal 1, @event.tickets.count

    assert new_ticket(ticket_type, complimentary: true).save
    assert_equal 2, @event.tickets.count
  end

  test "a ticket is refused once its type's sales have ended, or the event's sales closed at its end" do
    ticket_type = create_ticket_type(sales_end: 1.hour.from_now, quantity: 10)
    assert new_ticket(ticket_type).save

    ticket_type.set(sales_end: 1.minute.ago)
    assert_ticket_refused new_ticket(ticket_type), 'is not available as sales have ended'

    ticket_type.set(sales_end: nil)
    @event.set(start_time: 2.days.ago, end_time: 1.hour.ago)
    assert new_ticket(ticket_type).save
    @event.set(no_sales_after_end_time: true)
    assert_ticket_refused new_ticket(ticket_type), 'is not available as sales have ended'

    assert_equal 2, @event.tickets.count
  end

  test 'a ticket for monthly donors is refused to someone who gives less than its minimum each month' do
    ticket_type = create_ticket_type(minimum_monthly_donation: 10)
    donor = FactoryBot.create(:account)
    organisationship = donor.organisationships.create!(organisation: @organisation, monthly_donation_amount: 9.99, monthly_donation_currency: 'GBP')

    assert_ticket_refused new_ticket(ticket_type, account: donor), 'is not available to someone donating this amount'
    assert_ticket_refused new_ticket(ticket_type), 'is not available to someone donating this amount'

    organisationship.set(monthly_donation_amount: 10)
    assert new_ticket(ticket_type, account: donor).save
    assert_equal [donor.id], @event.tickets.pluck(:account_id)
  end

  test "a ticket type's event can't change" do
    ticket_type = create_ticket_type
    other_event = FactoryBot.create(:event, organisation: @organisation, account: @account)

    ticket_type = TicketType.find(ticket_type.id)
    ticket_type.event = other_event
    refute ticket_type.save
    assert_equal ['cannot be changed'], ticket_type.errors[:event]
    assert_equal @event.id, TicketType.find(ticket_type.id).event_id

    assert TicketType.find(ticket_type.id).update(name: 'Renamed')
  end

  test "a ticket type's prices, range, quantity and maximum per transaction can't be negative, and its range must go up" do
    ticket_type = create_ticket_type

    {
      { price_or_range: '10-5' } => [:range_max, 'must be > range min'],
      { price_or_range: '10-10' } => [:range_max, 'must be > range min'],
      { quantity: -1 } => [:quantity, 'must not be < 0'],
      { max_quantity_per_transaction: -1 } => [:max_quantity_per_transaction, 'must not be < 0']
    }.each do |attrs, (attribute, message)|
      tt = TicketType.find(ticket_type.id)
      tt.assign_attributes(price_or_range_submitted: true, price_or_range: tt.price.to_s, **attrs)
      refute tt.save, attrs.inspect
      assert_equal [message], tt.errors[attribute], attrs.inspect
    end

    # Set directly, as the price field can't give a negative one: '-1' reads as a range up to 1
    { price: [-1, nil, nil], range_min: [nil, -1, 5], range_max: [nil, 0, -1] }.each do |attribute, (price, min, max)|
      tt = TicketType.find(ticket_type.id)
      tt.assign_attributes(price: price, range_min: min, range_max: max)
      refute tt.save
      assert_includes tt.errors[attribute], 'must not be < 0'
    end

    ticket_type = TicketType.find(ticket_type.id)
    assert_equal [10, 2, nil, nil], [ticket_type.price, ticket_type.quantity, ticket_type.range_min, ticket_type.range_max]

    assert TicketType.find(ticket_type.id).update(price_or_range_submitted: true, price_or_range: '5-10', quantity: 0, max_quantity_per_transaction: 0)
    ticket_type = TicketType.find(ticket_type.id)
    assert_equal [nil, 5, 10, 0, 0], [ticket_type.price, ticket_type.range_min, ticket_type.range_max, ticket_type.quantity, ticket_type.max_quantity_per_transaction]
    assert TicketType.find(ticket_type.id).update(price_or_range_submitted: true, price_or_range: '0')
    assert_equal 0, TicketType.find(ticket_type.id).price
  end
end
