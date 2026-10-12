require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'ostruct'

class OrdersTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def create_complete_order
    create_event(prices: [0])
    @attendee = FactoryBot.create(:account)
    @order = @event.orders.create!(
      account: @attendee,
      currency: @event.currency,
      value: 0,
      payment_completed: true,
      original_description: 'Test order'
    )
  end

  def create_paid_order(event)
    Order.create!(
      event: event,
      account: FactoryBot.create(:account),
      value: 10,
      payment_completed: true,
      payment_intent: "pi_#{SecureRandom.hex(8)}",
      currency: event.currency
    )
  end

  def create_incomplete_order
    create_event(prices: [10])
    order = @event.orders.create!(
      account: FactoryBot.create(:account),
      currency: @event.currency,
      value: 10,
      payment_completed: false
    )
    order.tickets.create!(
      event: @event,
      account: order.account,
      ticket_type: @event.ticket_types.first,
      price: 10
    )
    order
  end

  def stub_completion_side_effects(order)
    counts = { tickets: 0, notifications: 0 }
    order.stub :send_tickets, proc { counts[:tickets] += 1 } do
      order.stub :create_order_notification, proc { counts[:notifications] += 1 } do
        yield counts
      end
    end
  end

  def with_stubbed_stripe_refunds
    refunds = []
    payment_intent = OpenStruct.new(charges: [OpenStruct.new(id: 'ch_test')])
    Stripe::PaymentIntent.stub :retrieve, payment_intent do
      Stripe::Refund.stub :create, proc { refunds << true } do
        yield refunds
      end
    end
  end

  # Tokens and public order confirmation links

  test 'creating an order generates a secret token' do
    create_complete_order

    assert @order.token.present?
    refute_equal @order.id.to_s, @order.token
    assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, @order.token)
  end

  def make_legacy_order
    @order.unset(:token)
    @order.reload
  end

  def referrer_policy
    last_response.headers['Referrer-Policy'] || last_response.headers['referrer-policy']
  end

  test 'find_by_id_or_token looks up tokenised orders by token only' do
    create_complete_order

    assert_equal @order, Order.find_by_id_or_token(@order.token)
    assert_equal @order, Order.complete.find_by_id_or_token(@order.token)
    assert_nil @event.orders.find_by_id_or_token(@order.id.to_s)
    assert_nil Order.incomplete.find_by_id_or_token(@order.token)
    assert_nil Order.find_by_id_or_token('not-a-real-token')
    assert_nil Order.find_by_id_or_token(BSON::ObjectId.new.to_s)
  end

  test 'find_by_id_or_token looks up legacy orders by mongo id' do
    create_complete_order
    make_legacy_order

    assert_equal @order, Order.find_by_id_or_token(@order.id.to_s)
    assert_equal @order, @event.orders.complete.find_by_id_or_token(@order.id.to_s)
  end

  test 'saving a legacy order does not backfill a token' do
    create_complete_order
    make_legacy_order

    @order.update_attributes!(original_description: 'Updated description')
    @order.reload

    assert_nil @order.token
    assert_equal @order.id.to_s, @order.public_id
    assert_equal @order, Order.find_by_id_or_token(@order.id.to_s)
  end

  test 'order confirmation is available via token' do
    create_complete_order

    get "/orders/#{@order.token}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, @event.name
    assert_equal 'no-referrer', referrer_policy
  end

  test 'order confirmation is not available via mongo id for tokenised orders' do
    create_complete_order

    get "/orders/#{@order.id}"
    assert_equal 404, last_response.status
  end

  test 'order confirmation remains available via mongo id for legacy orders' do
    create_complete_order
    make_legacy_order

    get "/orders/#{@order.id}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, @event.name
  end

  test 'order confirmation is not found for an unknown token' do
    get '/orders/not-a-real-token'
    assert_equal 404, last_response.status
  end

  test 'event page resolves ?order_id= by token' do
    create_complete_order

    get "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "/orders/#{@order.token}"
    assert_equal 'no-referrer', referrer_policy

    get "/e/#{@event.slug}?order_id=#{@order.id}&success=true"
    assert_equal 404, last_response.status

    get "/e/#{@event.slug}?order_id=not-a-real-token"
    assert_equal 404, last_response.status
  end

  test 'event page resolves ?order_id= by mongo id for legacy orders' do
    create_complete_order
    make_legacy_order

    get "/e/#{@event.slug}?order_id=#{@order.id}&success=true"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "/orders/#{@order.id}"
  end

  test 'event page shows the pending card instead of the success card for an incomplete order' do
    create_complete_order
    @order.set(payment_completed: false, oc_secret: 'ocsecret')

    get "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'Thanks for booking'
    assert_includes last_response.body, 'confirming your payment with Open Collective'
    assert_includes last_response.body, "/orders/#{@order.token}/payment_completed"
    refute_includes last_response.body, %(href="/orders/#{@order.token}")
    assert_equal 'no-referrer', referrer_policy
  end

  test 'event page shows neither card for an incomplete order without a payment return' do
    create_complete_order
    @order.set(payment_completed: false)

    get "/e/#{@event.slug}?order_id=#{@order.token}"
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'Thanks for booking'
    refute_includes last_response.body, 'Confirming your payment'
    refute_includes last_response.body, "/orders/#{@order.token}"
  end

  test 'event page sets referrer policy when the order is shown via GoCardless return' do
    create_complete_order
    @order.set(gocardless_payment_request_id: 'PRQtest')

    get "/e/#{@event.slug}?payment_request_id=PRQtest&success=true"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "/orders/#{@order.token}"
    assert_equal 'no-referrer', referrer_policy
  end

  test 'event page sets referrer policy while confirming a GoCardless payment' do
    create_complete_order
    @order.set(payment_completed: false, gocardless_billing_request_id: 'BRQpending')

    get "/e/#{@event.slug}?billing_request_id=BRQpending"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "/orders/#{@order.token}/payment_completed"
    assert_equal 'no-referrer', referrer_policy
  end

  # Ticketholder editing

  def create_complete_order_with_ticket
    create_complete_order
    @ticket = @order.tickets.create!(event: @event, account: @attendee, ticket_type: @event.ticket_types.first, price: 0)
  end

  def ticketholder_path(order_ref, action, ticket_ref: @ticket.public_id)
    "/events/#{@event.id}/orders/#{order_ref}/ticketholders/#{ticket_ref}/#{action}"
  end

  test 'creating a ticket generates a secret token' do
    create_complete_order_with_ticket

    assert_equal @ticket.token, @ticket.public_id
    assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, @ticket.token)
  end

  test 'ticketholder details of tokenised tickets cannot be edited with the ticket mongo id' do
    create_complete_order_with_ticket

    get ticketholder_path(@order.token, 'name', ticket_ref: @ticket.id)
    assert_equal 404, last_response.status

    post ticketholder_path(@order.token, 'name', ticket_ref: @ticket.id), name: 'Attacker'
    assert_equal 404, last_response.status
    assert_nil @ticket.reload.name
  end

  test 'ticketholder details of legacy tickets can be edited with the ticket mongo id' do
    create_complete_order_with_ticket
    @ticket.unset(:token)
    @ticket.reload
    assert_equal @ticket.id.to_s, @ticket.public_id

    post ticketholder_path(@order.token, 'name', ticket_ref: @ticket.id), name: 'Legacy Name'
    assert_equal 200, last_response.status
    assert_equal 'Legacy Name', @ticket.reload.name
  end

  test 'ticketholder details can be edited with the order token' do
    create_complete_order_with_ticket

    get ticketholder_path(@order.token, 'name')
    assert_equal 200, last_response.status
    assert_equal 'no-referrer', referrer_policy

    post ticketholder_path(@order.token, 'name'), name: 'New Name'
    assert_equal 200, last_response.status
    assert_equal 'New Name', @ticket.reload.name

    post ticketholder_path(@order.token, 'email'), email: 'holder@example.com', success: 1
    assert_equal 200, last_response.status
    assert_equal 'holder@example.com', @ticket.reload.email
  end

  test 'ticketholder details of legacy orders can be edited with the order mongo id' do
    create_complete_order_with_ticket
    make_legacy_order

    get ticketholder_path(@order.id, 'name')
    assert_equal 200, last_response.status

    post ticketholder_path(@order.id, 'name'), name: 'Legacy Name'
    assert_equal 200, last_response.status
    assert_equal 'Legacy Name', @ticket.reload.name
  end

  test 'ticketholder details of tokenised orders cannot be edited with the order mongo id' do
    create_complete_order_with_ticket

    get ticketholder_path(@order.id, 'name')
    assert_equal 404, last_response.status

    post ticketholder_path(@order.id, 'name'), name: 'Attacker'
    assert_equal 404, last_response.status
    assert_nil @ticket.reload.name

    post ticketholder_path(@order.id, 'email'), email: 'attacker@example.com', success: 1
    assert_equal 404, last_response.status
    assert_nil @ticket.reload.email
  end

  test 'check-in accepts the ticket token from the QR code, and legacy ticket mongo ids' do
    create_complete_order_with_ticket
    secret = OpenSSL::HMAC.hexdigest('SHA256', ENV['CHECK_IN_SECRET'], "check_in:#{@event.id}")[0, 32]

    post "/events/#{@event.id}/check_in/#{@ticket.token}", checked_in: true, secret: secret
    assert_equal 200, last_response.status
    assert @ticket.reload.checked_in

    post "/events/#{@event.id}/check_in/#{@ticket.id}", secret: secret
    assert_equal 403, last_response.status
    assert @ticket.reload.checked_in

    @ticket.unset(:token)
    post "/events/#{@event.id}/check_in/#{@ticket.id}", secret: secret
    assert_equal 200, last_response.status
    refute @ticket.reload.checked_in
  end

  test 'ticketholder routes return 404 for an unknown ticket' do
    create_complete_order_with_ticket

    get "/events/#{@event.id}/orders/#{@order.token}/ticketholders/#{BSON::ObjectId.new}/name"
    assert_equal 404, last_response.status
  end

  # Refunds

  test 'destroying an order refunds it' do
    create_event(prices: [10])
    order = create_paid_order(@event)
    with_stubbed_stripe_refunds do |refunds|
      order.destroy
      assert_equal 1, refunds.size
    end
  end

  test 'destroying an event refunds its orders' do
    create_event(prices: [10])
    create_paid_order(@event)
    with_stubbed_stripe_refunds do |refunds|
      @event.destroy
      assert_equal 1, refunds.size
    end
  end

  test 'destroying an event with prevent_order_refunds does not refund orders' do
    create_event(prices: [10])
    create_paid_order(@event)
    @event.prevent_order_refunds = true
    with_stubbed_stripe_refunds do |refunds|
      @event.destroy
      assert_empty refunds
    end
  end

  test 'successful refund emails the buyer a confirmation' do
    create_event(prices: [10])
    order = create_paid_order(@event)
    captured = nil
    with_stubbed_stripe_refunds do
      order.stub :notify_of_refund, proc { |amount:| captured = amount } do
        order.destroy
      end
    end
    assert_equal 10, captured
  end

  test 'failed refund does not email the buyer a confirmation' do
    create_event(prices: [10])
    order = create_paid_order(@event)
    notified = false
    EventPaymentMethod::Stripe.stub :refund, proc { |_record, on_error:, **|
      on_error.call(StandardError.new('already refunded'))
      true
    } do
      order.stub :notify_of_refund, proc { notified = true } do
        order.stub :notify_of_failed_refund, proc {} do
          order.destroy
        end
      end
    end
    refute notified
  end

  test 'refunding a ticket emails the buyer a confirmation' do
    create_event(prices: [10])
    ticket = @event.ticket_types.first.tickets.create!(
      event: @event,
      account: FactoryBot.create(:account),
      payment_completed: true,
      price: 10,
      payment_intent: 'pi_ticket'
    )
    captured = nil
    with_stubbed_stripe_refunds do
      ticket.stub :notify_of_refund, proc { |amount:| captured = amount } do
        ticket.refund
      end
    end
    assert_equal 10, captured
  end

  test 'refund confirmation email includes the amount' do
    create_event(prices: [10])
    html = EmailHelper.html(:refund, event: @event, amount: '£10', provider: 'Stripe', header_image_url: nil)

    assert_includes html, 'A refund of £10 has been issued'
    assert_includes html, @event.name
    assert_includes html, 'via Stripe'
    assert_includes html, 'few days to appear on your statement'
  end

  test 'connect refunds pass the connected account in request options' do
    create_event(prices: [10])
    @event.organisation.set(stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json)
    order = create_paid_order(@event)
    captured_opts = nil
    payment_intent = OpenStruct.new(charges: [OpenStruct.new(id: 'ch_test')])
    Stripe::PaymentIntent.stub :retrieve, payment_intent do
      Stripe::Refund.stub :create, proc { |_params, opts| captured_opts = opts } do
        order.destroy
      end
    end
    assert_equal 'acct_connect', captured_opts[:stripe_account]
    assert_equal ENV['STRIPE_SK'], captured_opts[:api_key]
  end

  # Concurrent completion claims

  test 'complete_or_restore completes an order only once' do
    order = create_incomplete_order

    stub_completion_side_effects(order) do |counts|
      order.complete_or_restore
      order.complete_or_restore
      assert_equal 1, counts[:tickets]
      assert_equal 1, counts[:notifications]
    end

    assert order.reload.payment_completed?
  end

  test 'complete_or_restore clears completing_at after an exception' do
    order = create_incomplete_order
    order.stub :payment_completed!, proc { raise 'boom' } do
      assert_raises(RuntimeError) { order.complete_or_restore }
    end

    assert_nil order.reload.completing_at
    refute order.payment_completed?
  end

  test 'free orders with a donation to Dandelion get a receipt PDF' do
    create_complete_order_with_ticket
    @order.set(application_fee_paid_to_dandelion: true)
    refute @order.donation_receipt?

    @order.donations.create!(account: @attendee, event: @event, amount: 10)
    assert @order.donation_receipt?
    assert @order.donation_receipt_pdf.render.start_with?('%PDF')

    @order.set(application_fee_paid_to_dandelion: false)
    refute @order.donation_receipt?
  end

  test 'paid orders with a donation to Dandelion do not get a receipt PDF' do
    create_complete_order
    @order.set(application_fee_paid_to_dandelion: true)
    @order.tickets.create!(event: @event, account: @attendee, ticket_type: @event.ticket_types.first, price: 5)
    @order.donations.create!(account: @attendee, event: @event, amount: 10)
    refute @order.donation_receipt?
  end

  def add_order_with_ticket(event)
    attendee = FactoryBot.create(:account)
    order = event.orders.create!(account: attendee, currency: event.currency, value: 10, payment_completed: true)
    order.tickets.create!(event: event, account: attendee, ticket_type: event.ticket_types.first, price: 10)
    attendee
  end

  # The queries a request runs, as [command, collection] pairs
  def queries_during
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |e| commands << [e.command_name, e.command.values.first] }
    subscriber.define_singleton_method(:succeeded) { |_| nil }
    subscriber.define_singleton_method(:failed) { |_| nil }
    Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
    yield
    commands
  ensure
    Mongoid.default_client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber) if subscriber
  end

  test 'event tickets and orders pages run the same queries however many orders there are' do
    create_event(prices: [10])
    @event.ticket_types.first.update!(quantity: 10)
    attendees = Array.new(2) { add_order_with_ticket(@event) }
    sign_in_with_rack(@account)

    counts = lambda do |path|
      queries = queries_during { get path }
      assert_equal 200, last_response.status
      { events: queries.count(%w[find events]), tickets: queries.count(%w[find tickets]), orders: queries.count(%w[find orders]) }
    end

    tickets_before = counts.call("/events/#{@event.id}/tickets")
    # Each table loads its page of records once, not again for each map, each and pagination_details
    assert_operator tickets_before[:tickets], :<=, 2
    orders_before = counts.call("/events/#{@event.id}/orders")
    assert_operator orders_before[:orders], :<=, 3
    get "/events/#{@event.id}/tickets"
    attendees.each { |attendee| assert_includes last_response.body, attendee.name }
    assert_includes last_response.body, 'Displaying <b>all 2</b> tickets'

    3.times { add_order_with_ticket(@event) }

    assert_equal tickets_before, counts.call("/events/#{@event.id}/tickets")
    assert_includes last_response.body, 'Displaying <b>all 5</b> tickets'
    assert_equal orders_before, counts.call("/events/#{@event.id}/orders")
    assert_includes last_response.body, 'Displaying <b>all 5</b> orders'
  end

  def create_complimentary_ticket(price: nil)
    create_event(prices: [10])
    @attendee = FactoryBot.create(:account)
    @attendee.tickets.create!(event: @event, ticket_type: @event.ticket_types.first, price: price, complimentary: true)
  end

  test 'complimentary tickets can be cancelled by their account' do
    ticket = create_complimentary_ticket
    assert ticket.cancellable?
    sign_in_with_rack(@attendee)

    get "/e/#{@event.slug}"
    assert_includes last_response.body, "/tickets/#{ticket.id}/destroy"

    get "/tickets/#{ticket.id}/confirm_cancel"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "/tickets/#{ticket.id}/destroy"

    post "/tickets/#{ticket.id}/destroy", from_confirm: '1'
    assert_equal "http://example.org/e/#{@event.slug}", last_response.location
    assert_nil Ticket.find(ticket.id)
  end

  test 'complimentary tickets cannot be cancelled by another account' do
    ticket = create_complimentary_ticket
    sign_in_with_rack(FactoryBot.create(:account))

    get "/tickets/#{ticket.id}/confirm_cancel"
    assert_equal 403, last_response.status
    post "/tickets/#{ticket.id}/destroy"
    assert_equal 403, last_response.status
    assert Ticket.find(ticket.id)
  end

  test 'priced complimentary tickets and tickets in orders cannot be cancelled as tickets' do
    ticket = create_complimentary_ticket(price: 10)
    refute ticket.cancellable?
    sign_in_with_rack(@attendee)
    post "/tickets/#{ticket.id}/destroy"
    assert_equal 403, last_response.status

    create_complete_order_with_ticket
    refute @ticket.cancellable?
  end
end
