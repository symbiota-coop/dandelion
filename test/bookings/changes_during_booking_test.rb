require_relative '../test_config'

# A ticket type an admin changes while someone is booking it. The booking's quote has already checked the ticket type
# is on sale and offered to the buyer (Quote#check_ticket_types), so a change landing after it, as the order is
# created, is caught only by OrderBuilder#create_tickets checking again, which must leave no order behind
class BookingsChangesDuringBookingTest < ActiveSupport::TestCase
  # Books one of ticket_type as the checkout form does, for a new guest each time, with the event loaded as
  # its request loads it. change runs as another request would, once the booking has checked its quote and created its order, before its
  # tickets. Gives the builder, or what it raised, and the emails sent, including by the jobs it queued
  def book_while(ticket_type, secret_ticket_type_id: nil, &change)
    builder = OrderBuilder.new(event: Event.find(@event.id), buyer: { name: 'Bea Booker', email: "bea-#{SecureRandom.hex(4)}@example.com" },
                               quantities: { ticket_type.id.to_s => 1 }, payment_method: 'rsvp',
                               secret_ticket_type_id: secret_ticket_type_id)
    changed = false
    builder.extend(Module.new do
      define_method(:create_order) do
        super().tap do
          change.call
          changed = true
        end
      end
    end)
    result = nil
    emails = recorded_emails do
      result = begin
        builder.call
        builder
      rescue OrderBuilder::Error => e
        e
      end
    end + emails_sent_by_jobs
    assert changed, 'The booking never got as far as creating its order'
    [result, emails]
  end

  def assert_booking_refused(result, emails, error_class)
    assert_kind_of error_class, result
    assert_equal 0, Order.and(event_id: @event.id).count
    assert_equal 0, Ticket.and(event_id: @event.id).count
    assert_empty emails.flat_map(&:recipients)
  end

  def assert_booked(result, emails)
    assert_kind_of OrderBuilder, result
    assert_equal 1, Ticket.and(event_id: @event.id, account_id: result.account.id).count
    assert_includes emails.flat_map(&:recipients), result.account.email
  end

  setup do
    create_event(prices: [0])
    # The event's own emails, like its organisation's first-event congratulations
    run_jobs
    @ticket_type = @event.ticket_types.first
  end

  test 'a ticket type hidden as it is booked is refused, unless the buyer came by its secret link' do
    assert_booking_refused(*book_while(@ticket_type) { @ticket_type.set(hidden: true) }, OrderBuilder::TicketTypeNotFound)

    @ticket_type.set(hidden: false)
    assert_booked(*book_while(@ticket_type, secret_ticket_type_id: @ticket_type.public_id) { @ticket_type.set(hidden: true) })
  end

  test 'a ticket type deleted as it is booked is refused' do
    assert_booking_refused(*book_while(@ticket_type) { @ticket_type.destroy }, OrderBuilder::TicketTypeNotFound)
  end

  test "a ticket type whose sales end as it is booked is refused, and one whose sales end is moved later isn't" do
    @ticket_type.set(sales_end: 1.hour.from_now)
    assert_booking_refused(*book_while(@ticket_type) { @ticket_type.set(sales_end: 1.minute.ago) }, OrderBuilder::SalesEnded)

    @ticket_type.set(sales_end: 1.hour.from_now)
    assert_booked(*book_while(@ticket_type) { @ticket_type.set(sales_end: 1.day.from_now) })
  end

  test 'a booking still going when the event ends is refused if the event takes no sales after its end' do
    @event.set(start_time: 2.hours.ago, end_time: 1.minute.from_now, no_sales_after_end_time: true)
    assert_booking_refused(*book_while(@ticket_type) { travel_to(2.minutes.from_now) }, OrderBuilder::SalesEnded)
    travel_back

    @event.set(no_sales_after_end_time: false)
    assert_booked(*book_while(@ticket_type) { travel_to(2.minutes.from_now) })
  end
end
