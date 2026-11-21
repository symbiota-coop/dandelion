require_relative '../test_config'
require_relative '../helpers/bookings_helpers'

# The price a ticket takes: its ticket type's fixed price, or the one the buyer chose for a range or pay-what-you-want
# ticket type, which Ticket checks as it's created and the purchase refuses before anything is made
class BookingTicketPricesTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include BookingsHelpers

  def build_ticket(**attrs)
    @event.tickets.build(account: FactoryBot.create(:account), ticket_type: @event.ticket_types.first, **attrs)
  end

  test "a pay-what-you-want ticket refuses a price that isn't a number, or is negative" do
    create_event(prices: [nil], suggested_donation: 0)

    [nil, 'abc', Float::INFINITY, -Float::INFINITY, Float::NAN].each do |price|
      ticket = build_ticket(price: price)
      refute ticket.valid?, "#{price.inspect} should be refused"
      assert_includes ticket.errors[:price], 'must be a number'
    end

    ticket = build_ticket(price: -1)
    refute ticket.valid?
    assert_includes ticket.errors[:price], 'is too low'

    [0, 7.5].each do |price|
      ticket = build_ticket(price: price)
      assert ticket.valid?, ticket.errors.full_messages.to_sentence
      assert_equal price, ticket.price
    end
    # Nothing to pay for a price of nothing
    assert build_ticket(price: 0).tap(&:valid?).payment_completed
    refute build_ticket(price: 7.5).tap(&:valid?).payment_completed
  end

  test 'a range ticket clamps its price to the ends of the range, but refuses one that is not a number' do
    create_event(prices: ['10-100'], suggested_donation: 0)

    { 5 => 10.0, -5 => 10.0, 150 => 100.0, 50 => 50.0, 10 => 10.0, 100 => 100.0 }.each do |chosen, price|
      ticket = build_ticket(price: chosen)
      assert ticket.valid?, ticket.errors.full_messages.to_sentence
      assert_equal price, ticket.price, "#{chosen} should be #{price}"
    end

    [nil, Float::INFINITY, Float::NAN].each do |price|
      ticket = build_ticket(price: price)
      refute ticket.valid?, "#{price.inspect} should be refused"
      assert_includes ticket.errors[:price], 'must be a number'
    end
  end

  test 'a complimentary ticket needs no price, and keeps the one it is given' do
    create_event(prices: ['10-100', nil], suggested_donation: 0)

    @event.ticket_types.each do |ticket_type|
      [nil, -5, 150].each do |price|
        ticket = @event.tickets.build(account: FactoryBot.create(:account), ticket_type: ticket_type, price: price, complimentary: true)
        assert ticket.valid?, ticket.errors.full_messages.to_sentence
        price.nil? ? assert_nil(ticket.price) : assert_equal(price.to_f, ticket.price)
        assert ticket.payment_completed
      end
    end
  end

  test "a fixed-price ticket takes its ticket type's price" do
    create_event(prices: [10], suggested_donation: 0)

    ticket = build_ticket
    assert ticket.valid?, ticket.errors.full_messages.to_sentence
    assert_equal 10.0, ticket.price
    refute ticket.payment_completed
  end

  test "a booked ticket keeps its price through saves that don't change it, and is priced again by those that do" do
    create_event(prices: ['10-30'], suggested_donation: 0)
    range = @event.ticket_types.first
    ticket = build_ticket(price: 10, payment_completed: true)
    ticket.save!
    assert_equal 10.0, ticket.discounted_price
    # The organiser sets the ticket's price on the Tickets page, then raises the range's minimum
    ticket.set(discounted_price: 7.5)
    range.update!(range_min: 15)

    ticket = Ticket.find(ticket.id)
    ticket.update!(email: 'holder@example.com')
    ticket = Ticket.find(ticket.id)
    assert_equal 10.0, ticket.price
    assert_equal 7.5, ticket.discounted_price

    ticket.update!(price: 12)
    ticket = Ticket.find(ticket.id)
    assert_equal 15.0, ticket.price
    assert_equal 15.0, ticket.discounted_price
  end

  test 'a purchase with a negative, non-numeric or out-of-range chosen price is refused, leaving no order or tickets' do
    covers_route 'POST /e/:slug/purchase'
    create_event(prices: [nil, '10-100'], suggested_donation: 0)
    pay_what_you_want, range = @event.ticket_types.map { |ticket_type| ticket_type.id.to_s }
    buyer = FactoryBot.create(:account)

    [[pay_what_you_want, '-1'], [pay_what_you_want, 'abc'], [pay_what_you_want, ''], [pay_what_you_want, '1e400'],
     [range, '5'], [range, '150'], [range, 'abc']].each do |ticket_type_id, price|
      post_purchase(@event, buyer, ticket_form: { quantities: { ticket_type_id => '1' }, prices: { ticket_type_id => price } })
      assert_equal 400, last_response.status, "#{price.inspect} should be refused"
      assert_includes JSON.parse(last_response.body)['error'], 'Choose a price per ticket'
      assert_equal 0, @event.orders.count
      assert_equal 0, @event.tickets.count
    end

    post_purchase(@event, buyer, ticket_form: { quantities: { pay_what_you_want => '1' }, prices: { pay_what_you_want => '0' } })
    assert_equal 200, last_response.status, last_response.body
    assert_equal 1, @event.orders.count
    assert_equal [0.0], @event.tickets.pluck(:price)
  end
end
