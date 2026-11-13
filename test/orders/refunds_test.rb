require_relative '../test_config'
require_relative '../helpers/orders_helpers'

# Refunding orders and tickets, through each payment provider, and the emails refunds send
class OrderRefundsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include OrdersHelpers

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
    covers 'events/delete-event-refund-choice@154629'
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
    covers 'events/delete-event-refund-choice@154629'
    create_event(prices: [10])
    create_paid_order(@event)
    @event.prevent_order_refunds = true
    with_stubbed_stripe_refunds do |refunds|
      destroy_and_refund(@event)
      assert_empty refunds
    end
  end

  test 'unticking Attempt to refund all orders deletes the event without refunding them' do
    covers 'events/delete-event-refund-choice@154629'
    covers_route 'POST /e/:slug/destroy'
    create_event(prices: [10])
    create_paid_order(@event)
    sign_in(@organisation.account)
    visit "/e/#{@event.slug}/delete"
    choose 'Delete event'
    uncheck 'Attempt to refund all orders'
    click_button 'Delete event'
    click_button 'Yes, delete event'
    assert page.has_content?('The event was deleted')
    assert @event.reload.deleted?
    assert_equal 0, Delayed::Job.and(handler: /refund_destroyed/).count
  end

  test 'cancelling an event with Attempt to refund all orders ticked refunds them' do
    covers 'events/delete-event-refund-choice@154629'
    create_event(prices: [10])
    create_paid_order(@event)
    sign_in(@organisation.account)
    visit "/e/#{@event.slug}/delete"
    assert page.has_checked_field?('Attempt to refund all orders')
    click_button 'Cancel event'
    click_button 'Yes, cancel event'
    assert page.has_content?('This event has been cancelled')
    assert_equal 1, Delayed::Job.and(handler: /refund_destroyed/).count
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
    covers_route 'POST /e/:slug/orders/:order_id/refund_and_destroy'
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
    covers_route 'POST /e/:slug/tickets/:ticket_id/destroy'
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
