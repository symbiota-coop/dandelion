require_relative '../test_config'
require_relative '../helpers/checkout_webhook_helpers'

# Paying with GoCardless instant bank pay and instalments, and its webhooks
class GocardlessPaymentsTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include CheckoutWebhookHelpers

  def stub_billing_request_checkout(billing_request)
    brq_params = {}
    flow_params = {}
    billing_requests = Object.new
    billing_requests.define_singleton_method(:create) do |opts|
      brq_params.merge!(opts[:params])
      billing_request
    end
    billing_request_flow = api_object(authorisation_url: nil)
    billing_request_flows = Object.new
    billing_request_flows.define_singleton_method(:create) do |opts|
      flow_params.merge!(opts[:params])
      billing_request_flow
    end
    client = api_object(billing_requests: billing_requests, billing_request_flows: billing_request_flows)
    [client, brq_params, flow_params]
  end

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

  test 'instant bank pay is only available for GBP and EUR events' do
    covers 'organisations/gocardless-gbp-eur-only@10a545'
    create_instant_event
    pm = EventPaymentMethod.object('gocardless_instant')

    assert pm.available?(@event)
    @event.set(currency: 'EUR')
    assert pm.available?(@event)
    @event.set(currency: 'SEK')
    refute pm.available?(@event)
  end

  test 'instant bank pay checkout stores the payment request id' do
    create_instant_event
    order = create_incomplete_order(@event, value: 10)
    billing_request = api_object(id: 'BRQ123', links: api_object(payment_request: 'PRQ123'))
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

  test 'instant bank pay return page says how long confirmation usually takes' do
    create_instant_event
    order = create_incomplete_order(@event, gocardless_payment_request_id: "PRQ#{SecureRandom.hex(4)}")

    get "/e/#{@event.slug}?payment_request_id=#{order.gocardless_payment_request_id}&success=true"

    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Confirming your payment'
    assert_includes last_response.body, 'You can close this page'
  end

  def create_instalment_event(instalment_count: 3)
    create_organisation(
      gocardless_access_token: 'sandbox_token',
      gocardless_endpoint_secret: 'webhook_secret',
      gocardless_instalments: true
    )
    create_event(prices: [30], gocardless_instalment_count: instalment_count)
  end

  def stub_gocardless_schedule_client(mandate_id: 'MD123')
    billing_request = api_object(
      status: 'fulfilled',
      links: api_object(mandate_request_mandate: mandate_id)
    )
    schedule = api_object(id: 'IS123')
    billing_requests = Object.new
    billing_requests.define_singleton_method(:get) { |_id| billing_request }
    instalment_schedules = Object.new
    captured = {}
    instalment_schedules.define_singleton_method(:create_with_schedule) do |opts|
      captured[:params] = opts[:params]
      schedule
    end
    client = api_object(
      billing_requests: billing_requests,
      instalment_schedules: instalment_schedules
    )
    [client, captured]
  end

  def billing_request_event(billing_request_id)
    api_object(
      resource_type: 'billing_requests',
      action: 'fulfilled',
      links: api_object(billing_request: billing_request_id),
      id: 'EV123'
    )
  end

  test 'instalments are only available for GBP and EUR events' do
    covers 'events/instalments-gbp-eur-only@4c16dc', 'organisations/gocardless-gbp-eur-only@10a545'
    create_instalment_event
    pm = EventPaymentMethod.object('gocardless_instalment')

    assert pm.available?(@event)
    @event.set(currency: 'EUR')
    assert pm.available?(@event)
    @event.set(currency: 'SEK')
    refute pm.available?(@event)
  end

  test 'instalment checkout stores the billing request id' do
    covers 'events/instalments-bank-account-in-event-currency@6c40e6'
    create_instalment_event(instalment_count: 4)
    order = create_incomplete_order(@event, value: 40)
    billing_request = api_object(id: 'BRQ123')
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
    covers 'events/instalment-tickets-issued-at-schedule-setup@98500a'
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

  test 'gocardless instalment count must be between 2 and 24' do
    covers 'events/instalment-count-field@f5776c'
    create_instalment_event
    { 1 => false, 2 => true, 24 => true, 25 => false }.each do |count, valid|
      @event.gocardless_instalment_count = count
      assert_equal valid, @event.valid?, "#{count} instalments"
      assert_includes @event.errors[:gocardless_instalment_count], 'must be between 2 and 24' unless valid
    end
  end

  test 'the gocardless instalments field appears once instalments are enabled on the organisation' do
    covers 'events/instalment-count-field@f5776c'
    create_organisation(gocardless_access_token: 'sandbox_token')
    create_event(prices: [30])
    sign_in_with_rack(@account)

    get "/e/#{@event.slug}/edit"
    assert last_response.ok?
    refute_includes last_response.body, 'event[gocardless_instalment_count]'

    @organisation.set(gocardless_instalments: true)
    get "/e/#{@event.slug}/edit"
    assert last_response.ok?
    assert_includes last_response.body, 'event[gocardless_instalment_count]'
  end

  test 'eur instalment checkout asks for a sepa mandate in euros' do
    covers 'events/instalments-bank-account-in-event-currency@6c40e6'
    create_instalment_event
    @event.set(currency: 'EUR')
    order = create_incomplete_order(@event, value: 30)
    client, brq_params, flow_params = stub_billing_request_checkout(api_object(id: 'BRQ123'))

    GoCardlessPro::Client.stub :new, client do
      EventPaymentMethod::GoCardlessInstalment.call(order: order, event: @event)
    end

    assert_equal 'sepa_core', brq_params[:mandate_request][:scheme]
    assert_equal 'EUR', brq_params[:mandate_request][:currency]
    assert_equal true, flow_params[:lock_currency]
  end

  test 'a failed later instalment does not cancel the order' do
    covers 'events/instalment-failures-not-cancelled@011b34'
    create_instalment_event
    order = create_incomplete_order(@event, value: 30, gocardless_billing_request_id: "BRQ#{SecureRandom.hex(4)}")
    client, = stub_gocardless_schedule_client
    deliver_gocardless_webhook(@organisation, billing_request_event(order.gocardless_billing_request_id), client)
    assert order.reload.payment_completed?

    failed = GoCardlessPro::Resources::Event.new(
      'id' => 'EV124',
      'resource_type' => 'payments',
      'action' => 'failed',
      'links' => { 'payment' => 'PM456' }
    )
    deliver_gocardless_webhook(@organisation, failed, client)

    assert_equal 200, last_response.status
    order = Order.find(order.id)
    assert order, 'the order was deleted'
    assert order.payment_completed?
    assert order.tickets.first.reload.payment_completed?
  end
end
