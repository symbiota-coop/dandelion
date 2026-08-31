require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'ostruct'

class WebhooksTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def create_incomplete_order(event, **attrs)
    price = attrs[:value] || event.ticket_types.first.price
    session_id = attrs[:session_id]
    order = Order.create!(
      {
        event: event,
        account: FactoryBot.create(:account),
        value: price,
        currency: event.currency,
        payment_completed: false
      }.merge(attrs)
    )
    ticket_attrs = {
      event: event,
      account: order.account,
      ticket_type: event.ticket_types.first,
      price: price
    }
    ticket_attrs[:session_id] = session_id if session_id
    order.tickets.create!(ticket_attrs)
    order
  end

  def stub_billing_request_checkout(billing_request)
    brq_params = {}
    flow_params = {}
    billing_requests = Object.new
    billing_requests.define_singleton_method(:create) do |opts|
      brq_params.merge!(opts[:params])
      billing_request
    end
    billing_request_flows = Object.new
    billing_request_flows.define_singleton_method(:create) do |opts|
      flow_params.merge!(opts[:params])
      OpenStruct.new
    end
    client = OpenStruct.new(billing_requests: billing_requests, billing_request_flows: billing_request_flows)
    [client, brq_params, flow_params]
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Stripe
  # ═══════════════════════════════════════════════════════════════════════════

  def checkout_completed_event(session_id)
    Stripe::Event.construct_from(
      {
        id: 'evt_test',
        type: 'checkout.session.completed',
        data: { object: { id: session_id } }
      }
    )
  end

  def deliver_stripe_webhook(organisation, stripe_event)
    Stripe::Webhook.stub :construct_event, stripe_event do
      header 'Stripe-Signature', 'sig'
      post "/o/#{organisation.slug}/stripe_webhook"
    end
  end

  def create_stripe_event(ticket_quantity: 10)
    create_organisation(stripe_endpoint_secret: 'whsec_test')
    create_event(prices: [10])
    @event.ticket_types.first.set(quantity: ticket_quantity)
  end

  def post_stripe_purchase(event, account)
    ticket_type = event.ticket_types.first
    header 'Accept', 'application/json'
    post "/events/#{event.id}/purchase",
         ticketForm: { quantities: { ticket_type.id.to_s => '1' } },
         detailsForm: {
           payment_method: 'stripe',
           account: { name: account.name, email: account.email }
         }
  end

  def with_stubbed_stripe_session(session_id: 'cs_test', payment_intent: 'pi_test')
    session = OpenStruct.new(id: session_id, payment_intent: payment_intent, url: 'https://checkout.stripe.com/test')
    Stripe::Checkout::Session.stub :create, session do
      yield session
    end
  end

  test 'checkout.session.completed webhook issues tickets' do
    create_organisation(stripe_endpoint_secret: 'whsec_test')
    create_event(prices: [10])
    order = create_incomplete_order(@event, value: 10, session_id: "cs_#{SecureRandom.hex(4)}")

    deliver_stripe_webhook(@organisation, checkout_completed_event(order.session_id))

    assert_equal 200, last_response.status
    assert order.reload.payment_completed?
    assert order.tickets.first.reload.payment_completed?
  end

  test 'checkout.session.completed webhook restores a deleted checkout' do
    create_organisation(stripe_endpoint_secret: 'whsec_test')
    create_event(prices: [10])
    order = create_incomplete_order(@event, value: 10, session_id: "cs_#{SecureRandom.hex(4)}")
    session_id = order.session_id
    order.destroy

    deliver_stripe_webhook(@organisation, checkout_completed_event(session_id))

    restored = Order.find(order.id)
    assert restored
    assert restored.payment_completed?
    assert restored.tickets.first
    assert restored.tickets.first.payment_completed?
  end

  test 'stripe purchase creates an incomplete order then webhook issues the ticket' do
    create_stripe_event
    buyer = FactoryBot.create(:account)

    with_stubbed_stripe_session do
      post_stripe_purchase(@event, buyer)
    end

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'cs_test', body['session_id']

    order = @event.orders.find_by(session_id: 'cs_test')
    assert order
    refute order.payment_completed?
    refute order.tickets.first.payment_completed?

    deliver_stripe_webhook(@organisation, checkout_completed_event(order.session_id))

    assert order.reload.payment_completed?
    assert order.tickets.first.reload.payment_completed?
  end

  test 'stripe purchase with quantity 1 sells out and rejects a second purchase' do
    create_stripe_event(ticket_quantity: 1)
    buyer = FactoryBot.create(:account)
    other = FactoryBot.create(:account)

    with_stubbed_stripe_session do
      post_stripe_purchase(@event, buyer)
    end

    assert_equal 200, last_response.status
    order = @event.orders.find_by(session_id: 'cs_test')
    assert order
    refute order.payment_completed?
    assert @event.reload.sold_out_cache
    assert @event.ticket_types.first.reload.sold_out_cache

    with_stubbed_stripe_session(session_id: 'cs_other') do
      post_stripe_purchase(@event, other)
    end

    assert_equal 400, last_response.status
    assert_equal 1, @event.orders.count
    assert_equal 1, @event.tickets.count

    deliver_stripe_webhook(@organisation, checkout_completed_event(order.session_id))

    assert order.reload.payment_completed?
    assert @event.reload.sold_out_cache
    assert_equal 1, @event.tickets.complete.count
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # GoCardless Instant Bank Pay
  # ═══════════════════════════════════════════════════════════════════════════

  def create_instant_event
    create_organisation(
      gocardless_access_token: 'sandbox_token',
      gocardless_endpoint_secret: 'webhook_secret',
      gocardless_instant_bank_pay: true
    )
    create_event(prices: [10])
  end

  def payment_confirmed_event(payment_request_id, payment_id: 'PM123')
    GoCardlessPro::Resources::Event.new(
      'id' => 'EV123',
      'resource_type' => 'payments',
      'action' => 'confirmed',
      'links' => {
        'payment' => payment_id,
        'payment_request' => payment_request_id
      }
    )
  end

  def deliver_gocardless_webhook(organisation, gc_event, client = nil)
    GoCardlessPro::Webhook.stub :parse, [gc_event] do
      if client
        GoCardlessPro::Client.stub :new, client do
          header 'Webhook-Signature', 'sig'
          post "/o/#{organisation.slug}/gocardless_webhook"
        end
      else
        header 'Webhook-Signature', 'sig'
        post "/o/#{organisation.slug}/gocardless_webhook"
      end
    end
  end

  test 'instant bank pay checkout stores the payment request id' do
    create_instant_event
    order = create_incomplete_order(@event, value: 10)
    billing_request = OpenStruct.new(id: 'BRQ123', links: OpenStruct.new(payment_request: 'PRQ123'))
    client, brq_params, flow_params = stub_billing_request_checkout(billing_request)

    GoCardlessPro::Client.stub :new, client do
      EventPaymentMethod::GoCardlessInstantBankPay.call(order: order, event: @event)
    end

    assert_equal 'PRQ123', order.reload.gocardless_payment_request_id
    assert_equal 'PRQ123', order.tickets.first.reload.gocardless_payment_request_id
    assert_equal 1000, brq_params[:payment_request][:amount]
    assert_equal 'GBP', brq_params[:payment_request][:currency]
    assert_includes flow_params[:redirect_uri], 'payment_request_id=PRQ123'
    assert_includes flow_params[:redirect_uri], 'success=true'
    assert_includes flow_params[:exit_uri], 'payment_request_id=PRQ123'
    assert_includes flow_params[:exit_uri], 'cancelled=true'
  end

  test 'confirmed payment webhook issues tickets for instant bank pay' do
    create_instant_event
    order = create_incomplete_order(@event, gocardless_payment_request_id: "PRQ#{SecureRandom.hex(4)}")

    deliver_gocardless_webhook(@organisation, payment_confirmed_event(order.gocardless_payment_request_id))

    assert_equal 200, last_response.status
    assert order.reload.payment_completed?
    assert_equal 'PM123', order.gocardless_payment_id
    assert order.tickets.first.reload.payment_completed?
    assert_equal 'PM123', order.tickets.first.gocardless_payment_id
  end

  test 'confirmed payment webhook restores a deleted instant bank pay checkout' do
    create_instant_event
    order = create_incomplete_order(@event, gocardless_payment_request_id: "PRQ#{SecureRandom.hex(4)}")
    payment_request_id = order.gocardless_payment_request_id
    order.destroy

    deliver_gocardless_webhook(@organisation, payment_confirmed_event(payment_request_id))

    restored = Order.find(order.id)
    assert restored
    assert restored.payment_completed?
    assert_equal 'PM123', restored.gocardless_payment_id
    assert restored.tickets.first
    assert restored.tickets.first.payment_completed?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # GoCardless instalments
  # ═══════════════════════════════════════════════════════════════════════════

  def create_instalment_event(instalment_count: 3)
    create_organisation(
      gocardless_access_token: 'sandbox_token',
      gocardless_endpoint_secret: 'webhook_secret',
      gocardless_instalments: true
    )
    create_event(prices: [30], gocardless_instalment_count: instalment_count)
  end

  def stub_gocardless_schedule_client(mandate_id: 'MD123')
    billing_request = OpenStruct.new(
      status: 'fulfilled',
      links: OpenStruct.new(mandate_request_mandate: mandate_id)
    )
    schedule = OpenStruct.new(id: 'IS123')
    billing_requests = Object.new
    billing_requests.define_singleton_method(:get) { |_id| billing_request }
    instalment_schedules = Object.new
    captured = {}
    instalment_schedules.define_singleton_method(:create_with_schedule) do |opts|
      captured[:params] = opts[:params]
      schedule
    end
    client = OpenStruct.new(
      billing_requests: billing_requests,
      instalment_schedules: instalment_schedules
    )
    [client, captured]
  end

  def billing_request_event(billing_request_id)
    OpenStruct.new(
      resource_type: 'billing_requests',
      action: 'fulfilled',
      links: OpenStruct.new(billing_request: billing_request_id),
      id: 'EV123'
    )
  end

  test 'instalment checkout stores the billing request id' do
    create_instalment_event(instalment_count: 4)
    order = create_incomplete_order(@event, value: 40)
    billing_request = OpenStruct.new(id: 'BRQ123')
    client, brq_params, flow_params = stub_billing_request_checkout(billing_request)

    GoCardlessPro::Client.stub :new, client do
      EventPaymentMethod::GoCardlessInstalment.call(order: order, event: @event)
    end

    assert_equal 'BRQ123', order.reload.gocardless_billing_request_id
    assert_equal 'BRQ123', order.tickets.first.reload.gocardless_billing_request_id
    assert_equal 'bacs', brq_params[:mandate_request][:scheme]
    assert_equal true, flow_params[:lock_currency]
    assert_includes flow_params[:redirect_uri], 'billing_request_id=BRQ123'
    assert_includes flow_params[:redirect_uri], 'success=true'
    assert_includes flow_params[:exit_uri], 'billing_request_id=BRQ123'
    assert_includes flow_params[:exit_uri], 'cancelled=true'
  end

  test 'fulfilled billing request webhook creates the schedule and issues tickets' do
    create_instalment_event
    order = create_incomplete_order(@event, value: 30, gocardless_billing_request_id: "BRQ#{SecureRandom.hex(4)}")
    client, captured = stub_gocardless_schedule_client

    deliver_gocardless_webhook(@organisation, billing_request_event(order.gocardless_billing_request_id), client)

    assert_equal [1000, 1000, 1000], captured[:params][:instalments][:amounts]
    assert_equal 'monthly', captured[:params][:instalments][:interval_unit]
    assert order.reload.payment_completed?
    assert order.tickets.first.reload.payment_completed?
  end

  test 'fulfilled billing request webhook restores a deleted checkout' do
    create_instalment_event
    order = create_incomplete_order(@event, value: 30, gocardless_billing_request_id: "BRQ#{SecureRandom.hex(4)}")
    billing_request_id = order.gocardless_billing_request_id
    order.destroy
    client, = stub_gocardless_schedule_client

    deliver_gocardless_webhook(@organisation, billing_request_event(billing_request_id), client)

    restored = Order.find(order.id)
    assert restored
    assert restored.payment_completed?
    assert restored.tickets.first
  end
end
