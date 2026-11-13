require_relative '../test_config'

# Bookings at the same time: each checks what's left before taking it, so without the locks a booking holds
# (OrderBuilder#booking_locks, RecordLock) two could both see the last place, a discount code's last use or the whole
# of the buyer's credit, and both take it. Each race runs several times, as one that oversells only does so some of
# the time
class BookingsCapacityRacesTest < ActiveSupport::TestCase
  ITERATIONS = 5

  # Runs the block in count threads at once: each sets up first (it's given a gate to wait at), and they're let through
  # together. Gives what each returned or raised
  def race(count, &block)
    gate = Queue.new
    ready = Queue.new
    threads = Array.new(count) do |index|
      Thread.new do
        Thread.current.report_on_exception = false
        wait = lambda do
          ready << true
          gate.pop
        end
        block.call(index, wait)
      end
    end
    count.times { ready.pop }
    count.times { gate << true }
    threads.map do |thread|
      thread.value
    rescue StandardError => e
      e
    end
  end

  # A booking as the checkout form makes one, by a buyer signed out, with its own copy of the event as each request
  # has. Waits at the gate once it's ready to book
  def book_racing(event, buyer, quantities, wait, payment_method: 'rsvp', idempotency_key: nil, signed_in: false, discount_code: nil)
    builder = OrderBuilder.new(event: Event.find(event.id), buyer: { name: buyer.name, email: buyer.email },
                               quantities: quantities.transform_keys { |ticket_type| ticket_type.id.to_s },
                               payment_method: payment_method, idempotency_key: idempotency_key,
                               signed_in_account: (Account.find(buyer.id) if signed_in), discount_code: discount_code)
    wait.call
    builder.call
  end

  # Races a booking by each buyer, of what quantities_for gives for each, and gives how many succeeded. Any refusal
  # but there not being enough left fails the test
  def race_bookings(event, buyers, payment_method: 'rsvp', &quantities_for)
    results = race(buyers.length) do |index, wait|
      book_racing(event, buyers[index], quantities_for.call(index), wait, payment_method: payment_method)
    end
    refusals = results.grep(Exception)
    refusals.each { |refusal| assert_kind_of OrderBuilder::NotEnoughTickets, refusal, refusal.full_message }
    results.length - refusals.length
  end

  # Stripe Checkout, giving each booking a session of its own, as orders' sessions are unique
  def with_stripe_sessions(&block)
    session = ->(*) { api_object(id: "cs_#{SecureRandom.hex}", payment_intent: "pi_#{SecureRandom.hex}", url: 'https://checkout.stripe.com/test') }
    Stripe::Checkout::Session.stub(:create, session, &block)
  end

  def buyers(count)
    Array.new(count) { FactoryBot.create(:account) }
  end

  def places_taken(event)
    Event.find(event.id).slots_taken
  end

  # An order by buyer for a ticket that isn't paid for yet, and so holds its place
  def hold_place(event, buyer)
    with_stripe_sessions { book_racing(event, buyer, { event.ticket_types.first => 1 }, -> {}, payment_method: 'stripe') }
    Order.find_by(event: event, account: buyer)
  end

  setup do
    create_organisation
  end

  test "two buyers at once for an event's last place: one gets it" do
    racers = buyers(2)
    (ITERATIONS * 4).times do
      event = create_event(prices: [0], capacity: 1)

      assert_equal 1, race_bookings(event, racers) { { event.ticket_types.first => 1 } }
      assert_equal 1, event.tickets.count
      assert Event.find(event.id).sold_out?
    end
  end

  test "ten buyers at once for an event's last three places: three get them" do
    racers = buyers(10)
    ITERATIONS.times do
      event = create_event(prices: [0], capacity: 3)

      assert_equal 3, race_bookings(event, racers) { { event.ticket_types.first => 1 } }
      assert_equal 3, event.tickets.count
    end
  end

  test 'buyers at once for more places than are left: the places are never exceeded' do
    racers = buyers(6)
    ITERATIONS.times do
      event = create_event(prices: [0], capacity: 5)

      # Two each: two bookings fit, and a third would take a sixth place
      assert_equal 2, race_bookings(event, racers) { { event.ticket_types.first => 2 } }
      assert_equal 4, places_taken(event)
    end
  end

  test "ten buyers at once for a ticket type's last two tickets: two get them" do
    racers = buyers(10)
    ITERATIONS.times do
      event = create_event
      ticket_type = FactoryBot.create(:ticket_type, event: event, quantity: 2)
      # Another type with plenty left, so the event isn't sold out
      FactoryBot.create(:ticket_type, event: event)

      assert_equal 2, race_bookings(event, racers) { { ticket_type => 1 } }
      assert_equal 2, ticket_type.tickets.count
      assert_equal 0, TicketType.find(ticket_type.id).number_of_tickets_available_in_single_purchase
    end
  end

  test "buyers at once for a ticket group's last places: its capacity isn't exceeded" do
    racers = buyers(10)
    ITERATIONS.times do
      event = create_event
      group = event.ticket_groups.create!(name: 'Weekend', capacity: 2)
      ticket_types = Array.new(2) { FactoryBot.create(:ticket_type, event: event, ticket_group: group) }

      assert_equal 2, race_bookings(event, racers) { |index| { ticket_types[index % 2] => 1 } }
      assert_equal 2, event.tickets.count
    end
  end

  test 'buyers at once of tickets taking two places, with one left: none get one, and one buyer of a single gets the last place' do
    racers = buyers(10)
    ITERATIONS.times do
      event = create_event(capacity: 3)
      single = FactoryBot.create(:ticket_type, event: event, slots: 1)
      couple = FactoryBot.create(:ticket_type, event: event, slots: 2)
      2.times { event.tickets.create!(ticket_type: single, account: FactoryBot.create(:account)) }

      assert_equal 1, race_bookings(event, racers) { |index| { index.even? ? couple : single => 1 } }
      assert_equal 0, couple.tickets.count
      assert_equal 3, places_taken(event)
    end
  end

  test 'buyers at once of tickets taking one and two places: the places are never exceeded' do
    racers = buyers(10)
    ITERATIONS.times do
      event = create_event(capacity: 3)
      single = FactoryBot.create(:ticket_type, event: event, slots: 1)
      couple = FactoryBot.create(:ticket_type, event: event, slots: 2)

      succeeded = race_bookings(event, racers) { |index| { index.even? ? couple : single => 1 } }
      # Three singles, or a couple and a single, whichever came first
      assert_includes [2, 3], succeeded
      assert_equal 3, places_taken(event)
    end
  end

  test "a booking lock left past its time, as by a booking whose process died, doesn't stop bookings" do
    event = create_event(prices: [0], capacity: 1)
    RecordLock.collection.insert_one(_id: "Event:#{event.id}", token: SecureRandom.uuid, expires_at: 1.second.ago)

    book_racing(event, FactoryBot.create(:account), { event.ticket_types.first => 1 }, -> {})
    assert_equal 1, event.tickets.count
    assert_equal 0, RecordLock.collection.count_documents(_id: "Event:#{event.id}")
  end

  test "a buyer booking two of an organisation's events at once spends their credit once" do
    ITERATIONS.times do
      buyer = FactoryBot.create(:account)
      organisationship = @organisation.organisationships.create!(account: buyer)
      organisationship.creditings.create!(account: @account, amount: 10, currency: 'GBP')
      events = Array.new(2) { create_event(prices: [10]) }

      results = with_stripe_sessions do
        race(2) do |index, wait|
          book_racing(events[index], buyer, { events[index].ticket_types.first => 1 }, wait, payment_method: 'stripe', signed_in: true)
        end
      end
      assert_empty results.grep(Exception)
      assert_equal [0, 10], events.map { |event| event.orders.first.credit_applied.to_i }.sort
      assert_equal 0, organisationship.credit_balance.cents
    end
  end

  test "buyers at once of two events with an organisation's discount code's last use: one gets it" do
    racers = buyers(2)
    ITERATIONS.times do |iteration|
      code = @organisation.discount_codes.create!(code: "LAST#{iteration}", percentage_discount: 50, maximum_uses: 1)
      events = Array.new(2) { create_event(prices: [10]) }

      results = with_stripe_sessions do
        race(2) do |index, wait|
          book_racing(events[index], racers[index], { events[index].ticket_types.first => 1 }, wait, payment_method: 'stripe', discount_code: code.code)
        end
      end
      refusals = results.grep(Exception)
      assert_equal 1, refusals.length, results.inspect
      assert_kind_of OrderBuilder::DiscountCodeInvalid, refusals.first
      assert_equal 1, code.orders.count
    end
  end

  test 'the same booking sent twice at once with one idempotency key makes one order' do
    index = 'event_id_1_account_id_1_idempotency_key_1_unique'
    Order.collection.indexes.create_one({ event_id: 1, account_id: 1, idempotency_key: 1 },
                                        name: index, unique: true, partial_filter_expression: { idempotency_key: { '$type' => 'string' } })
    buyer = FactoryBot.create(:account)
    ITERATIONS.times do |iteration|
      event = create_event(prices: [10])

      results = with_stripe_sessions do
        race(2) do |_index, wait|
          book_racing(event, buyer, { event.ticket_types.first => 1 }, wait, payment_method: 'stripe', idempotency_key: "key-#{iteration}")
        end
      end

      refusals = results.grep(Exception)
      assert_equal 1, refusals.length, results.inspect
      assert_kind_of OrderBuilder::IdempotencyKeyTaken, refusals.first
      assert_equal 1, event.orders.count
      assert_equal 1, event.tickets.count
    end
  ensure
    Order.collection.indexes.drop_one(index)
  end

  test "a hold that isn't paid for yet keeps its place from buyers at once" do
    racers = buyers(5)
    ITERATIONS.times do
      event = create_event(prices: [10], capacity: 1)
      hold = hold_place(event, FactoryBot.create(:account))
      refute hold.payment_completed

      succeeded = with_stripe_sessions { race_bookings(event, racers, payment_method: 'stripe') { { event.ticket_types.first => 1 } } }
      assert_equal 0, succeeded
      assert_equal [hold.id], event.tickets.pluck(:order_id)
    end
  end

  test "a hold past its time frees its place for one of the buyers at once, while the hourly errands delete it" do
    racers = buyers(5)
    ITERATIONS.times do
      event = create_event(prices: [10], capacity: 1)
      hold = hold_place(event, FactoryBot.create(:account))
      hold.set(created_at: Order::UNPAID_HOLD.ago - 1.minute)

      # The errands race the buyers too: those that book before the hold is deleted find no place
      results = with_stripe_sessions do
        race(racers.length + 1) do |index, wait|
          if index == racers.length
            wait.call
            Order.destroy_expired_holds
            :errands
          else
            book_racing(event, racers[index], { event.ticket_types.first => 1 }, wait, payment_method: 'stripe')
          end
        end
      end

      refusals = results.grep(Exception)
      refusals.each { |refusal| assert_kind_of OrderBuilder::NotEnoughTickets, refusal, refusal.full_message }
      assert_operator results.length - 1 - refusals.length, :<=, 1
      assert_nil Order.find(hold.id)
      assert_operator places_taken(event), :<=, 1

      # Once it's deleted, the place is there for whoever books next, if no one in the race took it
      next unless places_taken(event).zero?

      with_stripe_sessions { book_racing(event, FactoryBot.create(:account), { event.ticket_types.first => 1 }, -> {}, payment_method: 'stripe') }
      assert_equal 1, places_taken(event)
    end
  end
end
