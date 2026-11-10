require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class OrdersTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # Waits for something a request from the page does, such as a field that saves when it changes, to be done
  def wait_until(message)
    page.document.synchronize { raise Capybara::ExpectationNotMet, message unless yield }
  end

  # Changes a ticketholder field on the order's page, which saves it when it changes
  def change_ticketholder_field(field, value)
    fill_in field, with: value
    find_field(field).send_keys(:tab)
  end

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

  # The jobs queued to run a handle_asynchronously or .delay method
  def queued_jobs(method_name)
    Delayed::Job.and(handler: /\b#{method_name}(_without_delay)?\b/)
  end

  # The emails the jobs queued to run a method send
  def emails_from_jobs(method_name)
    recorded_emails { queued_jobs(method_name).each(&:invoke_job) }
  end

  # Stubs Stripe for refunds of a £10 order, its charge
  def with_stubbed_stripe_refunds
    refunds = []
    payment_intent = stripe_payment_intent('ch_test', amount: 1000)
    Stripe::PaymentIntent.stub :retrieve, payment_intent do
      Stripe::Refund.stub :create, proc { refunds << true } do
        yield refunds
      end
    end
  end

  # Destroying an order (or its event) queues its refund (Order#refund_later): this runs it, as the worker would
  def destroy_and_refund(record)
    record.destroy
    run_refund_jobs
  end

  def run_refund_jobs
    Delayed::Job.and(handler: /refund_destroyed/).each do |job|
      job.invoke_job
      job.destroy
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
    "/e/#{@event.slug}/orders/#{order_ref}/ticketholders/#{ticket_ref}/#{action}"
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

  test 'ticketholder details of legacy tickets can be edited on the order page' do
    create_complete_order_with_ticket
    @ticket.unset(:token)
    @ticket.reload
    assert_equal @ticket.id.to_s, @ticket.public_id

    visit "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert page.has_content? 'Thanks for booking'
    change_ticketholder_field 'name', 'Legacy Name'
    wait_until('name not saved') { @ticket.reload.name == 'Legacy Name' }
  end

  test 'ticketholder details can be edited on the order page' do
    create_complete_order_with_ticket

    visit "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert page.has_content? 'Thanks for booking'
    change_ticketholder_field 'name', 'New Name'
    wait_until('name not saved') { @ticket.reload.name == 'New Name' }
    change_ticketholder_field 'email', 'holder@example.com'
    wait_until('email not saved') { @ticket.reload.email == 'holder@example.com' }
  end

  test 'ticketholder fields are served with the order token kept from referrers' do
    create_complete_order_with_ticket

    get ticketholder_path(@order.token, 'name')
    assert_equal 200, last_response.status
    assert_equal 'no-referrer', referrer_policy
  end

  test 'ticketholder fields of legacy orders are served by the order mongo id' do
    create_complete_order_with_ticket
    make_legacy_order

    get ticketholder_path(@order.id, 'name')
    assert_equal 200, last_response.status
  end

  test 'ticketholder details of legacy orders can be edited on the order page, reached by the order mongo id' do
    create_complete_order_with_ticket
    make_legacy_order

    visit "/e/#{@event.slug}?order_id=#{@order.id}&success=true"
    assert page.has_content? 'Thanks for booking'
    change_ticketholder_field 'name', 'Legacy Name'
    wait_until('name not saved') { @ticket.reload.name == 'Legacy Name' }
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
    covers 'events/check-in-link-for-assistants@079793', 'organisations/check-in-scanner-link@4740c2'
    create_complete_order_with_ticket
    secret = OpenSSL::HMAC.hexdigest('SHA256', ENV['CHECK_IN_SECRET'], "check_in:#{@event.id}")[0, 32]

    post "/e/#{@event.slug}/check_in/#{@ticket.token}", checked_in: true, secret: secret
    assert_equal 200, last_response.status
    assert @ticket.reload.checked_in

    post "/e/#{@event.slug}/check_in/#{@ticket.token}", checked_in: true, secret: secret
    assert_equal 409, last_response.status # already checked in

    post "/e/#{@event.slug}/check_in/#{@ticket.id}", secret: secret
    assert_equal 403, last_response.status
    assert @ticket.reload.checked_in

    @ticket.unset(:token)
    post "/e/#{@event.slug}/check_in/#{@ticket.id}", secret: secret
    assert_equal 200, last_response.status
    refute @ticket.reload.checked_in

    post "/e/#{@event.slug}/check_in/#{@ticket.id}", secret: secret
    assert_equal 409, last_response.status # already not checked in
  end

  test 'ticketholder routes return 404 for an unknown ticket' do
    create_complete_order_with_ticket

    get "/e/#{@event.slug}/orders/#{@order.token}/ticketholders/#{BSON::ObjectId.new}/name"
    assert_equal 404, last_response.status
  end

  # Refunds

  test 'destroying an order refunds it' do
    covers 'events/refund-order-whole-payment@0235d0', 'events/refunds-to-original-method@119ce8'
    create_event(prices: [10])
    order = create_paid_order(@event)
    with_stubbed_stripe_refunds do |refunds|
      destroy_and_refund(order)
      assert_equal 1, refunds.size
    end
  end

  test 'destroying an event refunds its orders' do
    covers 'events/delete-event-refund-choice@eba303'
    create_event(prices: [10])
    create_paid_order(@event)
    with_stubbed_stripe_refunds do |refunds|
      # Refunds take seconds each, so the event is deleted without waiting for them, and the worker makes them
      @event.destroy
      assert_empty refunds
      run_refund_jobs
      assert_equal 1, refunds.size
    end
  end

  test 'destroying an event with prevent_order_refunds does not refund orders' do
    covers 'events/delete-event-refund-choice@eba303'
    create_event(prices: [10])
    create_paid_order(@event)
    @event.prevent_order_refunds = true
    with_stubbed_stripe_refunds do |refunds|
      destroy_and_refund(@event)
      assert_empty refunds
    end
  end

  test 'successful refund emails the buyer a confirmation' do
    covers 'events/refund-order-whole-payment@0235d0', 'events/refund-confirmation-email@e7eb67'
    create_event(prices: [10])
    order = create_paid_order(@event)
    captured = nil
    with_stubbed_stripe_refunds do
      order.stub :notify_of_refund, proc { |amount:| captured = amount } do
        order.refund
      end
    end
    assert_equal 10, captured
  end

  test 'Remove and refund order refunds only what is left of a Stripe charge, and nothing if it has all been refunded' do
    covers 'events/refund-order-only-whats-left@50bbbe'
    create_event(prices: [10])

    # Partly refunded already: refunds the rest, and the buyer's email says how much
    order = create_paid_order(@event)
    refund_params = []
    notified_amount = nil
    Stripe::PaymentIntent.stub :retrieve, stripe_payment_intent('ch_test', amount: 1000, amount_refunded: 400) do
      Stripe::Refund.stub :create, proc { |params, _opts| refund_params << params } do
        order.stub :notify_of_refund, proc { |amount:| notified_amount = amount } do
          order.refund
        end
      end
    end
    assert_equal [{ charge: 'ch_test', amount: 600 }], refund_params
    assert_equal 6, notified_amount

    # All refunded already, as when its tickets were refunded one by one: refunds nothing, and emails no one
    order = create_paid_order(@event)
    refund_params = []
    emails = nil
    Stripe::PaymentIntent.stub :retrieve, stripe_payment_intent('ch_test', amount: 1000, amount_refunded: 1000) do
      Stripe::Refund.stub :create, proc { |params, _opts| refund_params << params } do
        emails = recorded_emails { destroy_and_refund(order) }
      end
    end
    assert_empty refund_params
    assert_empty emails
    assert_nil Order.find(order.id)
  end

  test 'Remove and refund order refunds the rest of the application fee when it refunds the rest of a Stripe charge' do
    create_event(prices: [10])
    # A £10 order with a £2 donation to Dandelion, whose tickets' refunds (£8) left the fee with the platform. Refunding
    # the last £2 returns only £2 × 2/10 of the fee, so the rest is refunded on its own
    order = create_paid_order(@event)
    order.set(application_fee_amount: 2)
    fee_refunds = []
    Stripe::PaymentIntent.stub :retrieve, stripe_payment_intent('ch_test', amount: 1000, amount_refunded: 800, application_fee: 'fee_test') do
      Stripe::Refund.stub :create, proc { |_params, _opts| nil } do
        Stripe::ApplicationFee.stub :retrieve, api_object(id: 'fee_test', amount: 200, amount_refunded: 40) do
          Stripe::ApplicationFee.stub :create_refund, proc { |id, params, opts| fee_refunds << [id, params, opts[:stripe_account]] } do
            order.stub(:notify_of_refund, proc { |amount:| amount }) { order.refund }
          end
        end
      end
    end
    assert_equal [['fee_test', { amount: 160 }, nil]], fee_refunds
  end

  test 'Remove and refund order refunds the rest of the application fee when the Stripe charge is all refunded already' do
    create_event(prices: [10])
    # A £10 order with a £2 donation to Dandelion, whose tickets' refunds (£10) left the fee with the platform. There's
    # nothing of the charge to refund, so only the fee is refunded, and no one is emailed
    order = create_paid_order(@event)
    order.set(application_fee_amount: 2)
    refund_params = []
    fee_refunds = []
    emails = nil
    Stripe::PaymentIntent.stub :retrieve, stripe_payment_intent('ch_test', amount: 1000, amount_refunded: 1000, application_fee: 'fee_test') do
      Stripe::Refund.stub :create, proc { |params, _opts| refund_params << params } do
        Stripe::ApplicationFee.stub :retrieve, api_object(id: 'fee_test', amount: 200, amount_refunded: 0) do
          Stripe::ApplicationFee.stub :create_refund, proc { |id, params, opts| fee_refunds << [id, params, opts[:stripe_account]] } do
            emails = recorded_emails { destroy_and_refund(order) }
          end
        end
      end
    end
    assert_empty refund_params
    assert_equal [['fee_test', { amount: 200 }, nil]], fee_refunds
    assert_empty emails
  end

  test 'failed refund does not email the buyer a confirmation' do
    covers 'events/refund-confirmation-email@e7eb67'
    create_event(prices: [10])
    order = create_paid_order(@event)
    notified = false
    EventPaymentMethod::Stripe.stub :refund, proc { |_record, on_error:, **|
      on_error.call(StandardError.new('already refunded'))
      true
    } do
      order.stub :notify_of_refund, proc { notified = true } do
        order.stub :notify_of_failed_refund, proc {} do
          order.refund
        end
      end
    end
    refute notified
  end

  test 'refunding a ticket emails the buyer a confirmation' do
    covers 'events/refund-ticket-own-price@985cff', 'events/refund-confirmation-email@e7eb67'
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
    covers 'events/refund-confirmation-email@e7eb67'
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
    payment_intent = stripe_payment_intent('ch_test')
    Stripe::PaymentIntent.stub :retrieve, payment_intent do
      Stripe::Refund.stub :create, proc { |_params, opts| captured_opts = opts } do
        destroy_and_refund(order)
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
    covers 'events/free-order-donation-receipt@388e58'
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
    covers 'events/free-order-donation-receipt@388e58'
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

  test "the organisation orders page shows each event's revenue, reading every event's tickets at once" do
    create_event(prices: [10])
    sign_in_with_rack(@account)
    sell = lambda do |event, price|
      order = event.orders.create!(account: FactoryBot.create(:account), currency: event.currency, value: price, payment_completed: true)
      order.tickets.create!(event: event, account: order.account, ticket_type: event.ticket_types.first, price: price, payment_completed: true)
    end
    # An event's column in its orders' rows: its name, countdown, progress and revenue
    event_cell = ->(event) { last_response.body[%r{<td>\s*<a href="/e/#{event.slug}">.*?</td>}m] }
    ticket_queries = lambda do
      queries = queries_during { get "/o/#{@organisation.slug}/orders" }
      assert_equal 200, last_response.status
      queries.count(%w[find tickets])
    end

    sell.call(@event, 10)
    one_event = ticket_queries.call
    assert_includes event_cell.call(@event), '£10'

    others = [25, 40].each_with_index.map do |price, i|
      create_event(prices: [price], as: :"event#{i}").tap { |event| 2.times { sell.call(event, price) } }
    end
    assert_equal one_event, ticket_queries.call
    assert_includes event_cell.call(@event), '£10'
    assert_includes event_cell.call(others[0]), '£50'
    assert_includes event_cell.call(others[1]), '£80'
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

    tickets_before = counts.call("/e/#{@event.slug}/tickets")
    # Each table loads its page of records once, not again for each map, each and pagination_details
    assert_operator tickets_before[:tickets], :<=, 2
    orders_before = counts.call("/e/#{@event.slug}/orders")
    # The table's page, its accounts and booking questions, and the stats row's check for incomplete orders
    assert_operator orders_before[:orders], :<=, 4
    get "/e/#{@event.slug}/tickets"
    attendees.each { |attendee| assert_includes last_response.body, attendee.name }
    assert_includes last_response.body, 'Displaying <b>all 2</b> tickets'

    3.times { add_order_with_ticket(@event) }

    assert_equal tickets_before, counts.call("/e/#{@event.slug}/tickets")
    assert_includes last_response.body, 'Displaying <b>all 5</b> tickets'
    assert_equal orders_before, counts.call("/e/#{@event.slug}/orders")
    assert_includes last_response.body, 'Displaying <b>all 5</b> orders'
  end

  def create_complimentary_ticket(price: nil)
    create_event(prices: [10])
    @attendee = FactoryBot.create(:account)
    @attendee.tickets.create!(event: @event, ticket_type: @event.ticket_types.first, price: price, complimentary: true)
  end

  test 'complimentary tickets can be cancelled by their account' do
    covers 'events/attendees-cancel-free-rsvps@2edb4c'
    ticket = create_complimentary_ticket
    assert ticket.cancellable?
    sign_in(@attendee)

    visit "/e/#{@event.slug}"
    assert page.has_link? 'Cancel RSVP', href: "/tickets/#{ticket.id}/destroy"

    # As the Cancel your RSVP link in their ticket email does
    visit "/tickets/#{ticket.id}/confirm_cancel"
    click_button 'Yes, cancel my RSVP'
    assert page.has_current_path? "/e/#{@event.slug}"
    assert_nil Ticket.find(ticket.id)
  end

  test 'complimentary tickets cannot be cancelled by another account' do
    covers 'events/attendees-cancel-free-rsvps@2edb4c'
    ticket = create_complimentary_ticket
    sign_in_with_rack(FactoryBot.create(:account))

    get "/tickets/#{ticket.id}/confirm_cancel"
    assert_equal 403, last_response.status
    post "/tickets/#{ticket.id}/destroy"
    assert_equal 403, last_response.status
    assert Ticket.find(ticket.id)
  end

  test 'priced complimentary tickets and tickets in orders cannot be cancelled as tickets' do
    covers 'events/paid-orders-not-cancellable@9106dd'
    ticket = create_complimentary_ticket(price: 10)
    refute ticket.cancellable?
    sign_in_with_rack(@attendee)
    post "/tickets/#{ticket.id}/destroy"
    assert_equal 403, last_response.status

    create_complete_order_with_ticket
    refute @ticket.cancellable?
  end

  test 'free orders can be cancelled by their account, which emails them and tells the waitlist a place is available' do
    covers 'events/attendees-cancel-free-rsvps@2edb4c', 'events/cancellation-emails-and-waitlist@ddd281'
    Delayed::Job.delete_all
    create_complete_order_with_ticket
    @event.set(capacity: 1)
    @event.refresh_sold_out_cache_and_notify_waitlist
    Waitship.create!(event: @event, account: FactoryBot.create(:account))
    assert Event.find(@event.id).sold_out_cache
    sign_in(@attendee)

    visit "/e/#{@event.slug}"
    assert page.has_content? 'Your orders'
    click_link_and_confirm 'Cancel RSVP'
    wait_until('order not cancelled') { queued_jobs(:send_rsvp_cancelled_email).exists? && queued_jobs(:send_waitlist_tickets_available).exists? }
    assert_nil Order.find(@order.id)
    assert_nil Ticket.find(@ticket.id)

    assert_equal [[@attendee.email]], emails_from_jobs(:send_rsvp_cancelled_email).map(&:recipients)
    assert_equal 1, queued_jobs(:send_waitlist_tickets_available).count
  end

  test 'cancelling a complimentary ticket emails its account to confirm' do
    covers 'events/cancellation-emails-and-waitlist@ddd281'
    Delayed::Job.delete_all
    ticket = create_complimentary_ticket
    sign_in(@attendee)

    visit "/e/#{@event.slug}"
    assert page.has_content? 'Your tickets'
    click_link_and_confirm 'Cancel RSVP'
    wait_until('ticket not cancelled') { queued_jobs(:send_rsvp_cancelled_email).exists? }
    assert_nil Ticket.find(ticket.id)
    assert_equal [[@attendee.email]], emails_from_jobs(:send_rsvp_cancelled_email).map(&:recipients)
  end

  test 'the Cancel your RSVP links in ticket and reminder emails cancel a free order' do
    covers 'events/attendees-cancel-free-rsvps@2edb4c'
    create_complete_order_with_ticket
    html = EmailHelper.html(:tickets, event: @event, order: @order, account: @attendee, tickets_table: '', header_image_url: nil)
    assert_includes html, "/orders/#{@order.id}/confirm_cancel?link_token=%recipient.token%"
    @event.set(reminder_hours_before: 24)

    reminder = recorded_emails { @event.send_reminders_without_delay(@attendee.id) }.find { |email| email.recipients.any? }
    assert_includes reminder.html, '%recipient.cancel_rsvp_url%'
    cancel_url = URI(reminder.variables[@attendee.email]['cancel_rsvp_url'])
    assert_equal "/orders/#{@order.id}/confirm_cancel", cancel_url.path

    # Not signed in: the link's token signs them in
    visit cancel_url.request_uri
    click_button 'Yes, cancel my RSVP'
    assert page.has_current_path? "/e/#{@event.slug}"
    assert_nil Order.find(@order.id)
  end

  test 'paid orders and tickets cannot be cancelled or refunded by their attendee' do
    covers 'events/paid-orders-not-cancellable@9106dd', 'events/attendees-cannot-refund@1c589f'
    create_event(prices: [10])
    order = create_paid_order(@event)
    ticket = order.tickets.create!(event: @event, account: order.account, ticket_type: @event.ticket_types.first, price: 10,
                                   payment_completed: true, payment_intent: order.payment_intent)
    sign_in_with_rack(order.account)

    get "/e/#{@event.slug}"
    refute_includes last_response.body, "/orders/#{order.id}/destroy"
    with_stubbed_stripe_refunds do |refunds|
      get "/orders/#{order.id}/confirm_cancel"
      assert_equal 403, last_response.status
      post "/orders/#{order.id}/destroy"
      assert_equal 403, last_response.status
      post "/tickets/#{ticket.id}/destroy"
      assert_equal 403, last_response.status
      post "/e/#{@event.slug}/orders/#{order.id}/refund_and_destroy"
      post "/e/#{@event.slug}/tickets/#{ticket.id}/refund_and_destroy"
      assert_empty refunds
    end
    assert Order.find(order.id)
    assert Ticket.find(ticket.id)
  end

  # Order notifications and confirmations

  test 'order notifications are emailed to facilitators only when the event sends them' do
    covers 'events/order-notification-emails@73c132'
    Delayed::Job.delete_all
    order = create_incomplete_order
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    @event.set(send_order_notifications: true)

    order.complete_or_restore
    # The event's creator is a facilitator too
    assert_equal [[@account.email, facilitator.email].sort], (emails_from_jobs(:send_notification).map { |email| email.recipients.sort })
    refute_includes @event.event_facilitators, order.account

    Delayed::Job.delete_all
    order = create_incomplete_order
    @event.set(send_order_notifications: false)
    order.complete_or_restore
    assert order.reload.payment_completed
    assert_equal 0, queued_jobs(:send_notification).count
  end

  test 'only the orderer gets the order confirmation unless the event sends it to other ticketholders' do
    covers 'events/ticketholder-confirmation-setting@b8610e'
    Delayed::Job.delete_all
    create_complete_order_with_ticket
    @ticket.set(email: 'holder@example.com')
    assert_equal [[@attendee.email]], recorded_emails { @order.send_tickets_without_delay }.map(&:recipients)

    @ticket.set(email: nil)
    visit "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert page.has_content? 'Thanks for booking'
    change_ticketholder_field 'email', 'holder@example.com'
    wait_until('email not saved') { @ticket.reload.email == 'holder@example.com' }

    @event.set(send_ticketholder_confirmation: true)
    visit "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert page.has_content? 'receive the order confirmation'
    change_ticketholder_field 'email', 'friend@example.com'
    wait_until('order confirmation not sent') { queued_jobs(:send_ticket).exists? }
    # Only for the second email, as the first was entered while the event didn't send it
    assert_equal [['friend@example.com']], emails_from_jobs(:send_ticket).map(&:recipients)
  end

  test 'the ticket keeps its token, which its PDF holds, when the ticketholder changes' do
    covers 'events/ticket-pdf-works-after-transfer@a22930'
    create_complete_order_with_ticket
    token = @ticket.public_id

    visit "/e/#{@event.slug}?order_id=#{@order.token}&success=true"
    assert page.has_content? 'Thanks for booking'
    change_ticketholder_field 'name', 'New Holder'
    wait_until('name not saved') { @ticket.reload.name == 'New Holder' }
    change_ticketholder_field 'email', 'newholder@example.com'
    wait_until('email not saved') { @ticket.reload.email == 'newholder@example.com' }
    assert_equal token, @ticket.public_id
  end

  test 'the original ticket PDF still checks in after the ticketholder changes' do
    covers 'events/ticket-pdf-works-after-transfer@a22930'
    create_complete_order_with_ticket
    token = @ticket.public_id
    @ticket.set(name: 'New Holder', email: 'newholder@example.com')

    secret = OpenSSL::HMAC.hexdigest('SHA256', ENV['CHECK_IN_SECRET'], "check_in:#{@event.id}")[0, 32]
    post "/e/#{@event.slug}/check_in/#{token}", checked_in: true, secret: secret
    assert_equal 200, last_response.status
    assert @ticket.reload.checked_in
  end

  # Refunds by provider

  def create_order_paid_with(event, **payment_ids)
    Order.create!(event: event, account: FactoryBot.create(:account), value: 10, payment_completed: true,
                  currency: event.currency, **payment_ids)
  end

  test 'Mollie, PayPal and GoCardless refunds go back to the payment they were made with' do
    covers 'events/refunds-to-original-method@119ce8'
    create_event(prices: [10])

    mollie_refunds = []
    Mollie::Payment::Refund.stub :create, proc { |params| mollie_refunds << params } do
      destroy_and_refund(create_order_paid_with(@event, mollie_payment_id: 'tr_mollie'))
    end
    assert_equal [['tr_mollie', '10.00']], (mollie_refunds.map { |params| [params[:payment_id], params[:amount][:value]] })

    paypal_refunds = []
    paypal = Object.new
    paypal.define_singleton_method(:refund_capture) { |capture_id, amount:, currency:| paypal_refunds << [capture_id, amount, currency] }
    EventPaymentMethod::Paypal.stub :client_for, paypal do
      destroy_and_refund(create_order_paid_with(@event, paypal_capture_id: 'CAPTURE1'))
    end
    assert_equal [['CAPTURE1', 10, 'GBP']], paypal_refunds

    gocardless_refunds = []
    payments = Object.new
    payments.define_singleton_method(:get) { |_id| Struct.new(:amount_refunded).new(0) }
    refunds = Object.new
    refunds.define_singleton_method(:create) { |params:| gocardless_refunds << params }
    gocardless = Struct.new(:payments, :refunds).new(payments, refunds)
    GoCardlessPro::Client.stub :new, gocardless do
      destroy_and_refund(create_order_paid_with(@event, gocardless_payment_id: 'PM123'))
    end
    assert_equal [['PM123', 1000]], (gocardless_refunds.map { |params| [params[:links][:payment], params[:amount]] })
  end

  test 'Remove and refund order refunds the whole payment, including a donation to Dandelion' do
    covers 'events/refund-order-whole-payment@0235d0'
    create_event(prices: [10])
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json)
    order = create_paid_order(@event)
    order.set(value: 15, application_fee_amount: 5, application_fee_paid_to_dandelion: true)
    order.tickets.create!(event: @event, account: order.account, ticket_type: @event.ticket_types.first, price: 10, payment_completed: true)
    order.donations.create!(account: order.account, event: @event, amount: 5)
    sign_in(@account)

    visit "/e/#{@event.slug}/orders"
    refund_params = []
    Stripe::PaymentIntent.stub :retrieve, stripe_payment_intent('ch_test') do
      Stripe::Refund.stub :create, proc { |params, _opts| refund_params << params } do
        click_button 'Actions'
        click_link_and_confirm 'Remove and refund order'
        assert page.has_content? 'No orders found'
        run_refund_jobs
      end
    end
    # No amount refunds the whole charge
    assert_equal [{ charge: 'ch_test', refund_application_fee: true }], refund_params
    assert_nil Order.find(order.id)
  end

  test 'Remove order and Remove ticket remove without refunding' do
    covers 'events/remove-without-refund@febcde'
    create_event(prices: [10])
    order = create_paid_order(@event)
    other_order = create_paid_order(@event)
    ticket = other_order.tickets.create!(event: @event, account: other_order.account, ticket_type: @event.ticket_types.first, price: 10,
                                         payment_completed: true, payment_intent: other_order.payment_intent)
    sign_in(@account)

    with_stubbed_stripe_refunds do |refunds|
      visit "/e/#{@event.slug}/orders"
      within(:xpath, "//tr[.//a[@href='/e/#{@event.slug}/orders/#{order.id}/destroy']]") do
        click_button 'Actions'
        click_link_and_confirm 'Remove order'
      end
      assert page.has_content? 'Displaying 1 order'

      visit "/e/#{@event.slug}/tickets"
      click_button 'Actions'
      click_link_and_confirm 'Remove ticket'
      assert page.has_content? 'No tickets found'
      assert_empty refunds
    end
    assert_nil Order.find(order.id)
    assert_nil Ticket.find(ticket.id)
  end

  test 'refund options appear only for Stripe, GoCardless, Mollie and PayPal payments' do
    covers 'events/refunds-to-original-method@119ce8', 'events/refund-options-only-for-providers@a51af0'
    create_event(prices: [10])
    @event.ticket_types.first.set(quantity: 20)
    refundable = [{ payment_intent: 'pi_1' }, { gocardless_payment_id: 'PM1' }, { mollie_payment_id: 'tr_1' }, { paypal_capture_id: 'CAP1' }]
    not_refundable = [{ oc_secret: 'oc1' }, { evm_secret: 'evm1' }, {}]
    orders = (refundable + not_refundable).map do |payment_ids|
      order = create_order_paid_with(@event, **payment_ids)
      order.tickets.create!(event: @event, account: order.account, ticket_type: @event.ticket_types.first, price: 10, payment_completed: true,
                            **payment_ids.slice(:payment_intent, :gocardless_payment_id, :mollie_payment_id, :paypal_capture_id))
      order
    end
    sign_in_with_rack(@account)

    get "/e/#{@event.slug}/orders"
    assert_equal 200, last_response.status
    orders.each_with_index do |order, i|
      assert_includes last_response.body, "/e/#{@event.slug}/orders/#{order.id}/destroy"
      assert_equal i < refundable.size, last_response.body.include?("/e/#{@event.slug}/orders/#{order.id}/refund_and_destroy"), order.attributes.slice('payment_intent', 'gocardless_payment_id', 'mollie_payment_id', 'paypal_capture_id', 'oc_secret', 'evm_secret').inspect
    end

    get "/e/#{@event.slug}/tickets"
    assert_equal 200, last_response.status
    orders.each_with_index do |order, i|
      ticket = order.tickets.first
      assert_includes last_response.body, "/e/#{@event.slug}/tickets/#{ticket.id}/destroy"
      assert_equal i < refundable.size, last_response.body.include?("/e/#{@event.slug}/tickets/#{ticket.id}/refund_and_destroy")
    end
  end

  test 'a failed refund emails the organiser the error' do
    covers 'events/refund-failure-email@176a81'
    create_event(prices: [10])
    order = create_paid_order(@event)
    emails = nil
    Stripe::PaymentIntent.stub :retrieve, stripe_payment_intent('ch_test') do
      Stripe::Refund.stub :create, proc { raise Stripe::InvalidRequestError.new('Insufficient funds in Stripe account.', nil) } do
        emails = recorded_emails { destroy_and_refund(order) }
      end
    end
    email = emails.find { |e| e.recipients.include?(@account.email) }
    assert email
    assert_includes email.html, 'Insufficient funds in Stripe account.'
  end

  test 'a failed refund of a deleted event emails its facilitators, though their facilitations went with the event' do
    covers 'events/refund-failure-email@176a81'
    create_event(prices: [10])
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    create_paid_order(@event)
    emails = nil
    Stripe::PaymentIntent.stub :retrieve, stripe_payment_intent('ch_test') do
      Stripe::Refund.stub :create, proc { raise Stripe::InvalidRequestError.new('Insufficient funds in Stripe account.', nil) } do
        emails = recorded_emails { destroy_and_refund(@event) }
      end
    end
    assert_empty EventFacilitation.and(event_id: @event.id)
    assert(emails.any? { |e| e.recipients.include?(facilitator.email) })
  end
end
