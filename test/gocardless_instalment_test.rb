require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'ostruct'
require 'rack/test'

class GoCardlessInstalmentTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def app
    Padrino.application
  end

  def create_event(instalment_count: 3)
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(
      :organisation,
      account: account,
      gocardless_access_token: 'sandbox_token',
      gocardless_endpoint_secret: 'webhook_secret',
      gocardless_instalments: true
    )
    FactoryBot.create(
      :event,
      organisation: organisation,
      account: account,
      last_saved_by: account,
      prices: [30],
      gocardless_instalment_count: instalment_count
    )
  end

  def create_instalment_order(event)
    order = Order.create!(
      event: event,
      account: FactoryBot.create(:account),
      value: 30,
      currency: event.currency,
      payment_completed: false,
      gocardless_billing_request_id: "BRQ#{SecureRandom.hex(4)}"
    )
    order.tickets.create!(
      event: event,
      account: order.account,
      ticket_type: event.ticket_types.first,
      price: 30
    )
    order
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

  def deliver_webhook(organisation, gc_event, client)
    GoCardlessPro::Webhook.stub :parse, [gc_event] do
      GoCardlessPro::Client.stub :new, client do
        header 'Webhook-Signature', 'sig'
        post "/o/#{organisation.slug}/gocardless_webhook"
      end
    end
  end

  test 'checkout stores the billing request id' do
    event = create_event(instalment_count: 4)
    order = Order.create!(event: event, account: FactoryBot.create(:account), value: 40, currency: event.currency)
    order.tickets.create!(event: event, account: order.account, ticket_type: event.ticket_types.first, price: 40)

    billing_request = OpenStruct.new(id: 'BRQ123')
    billing_request_flow = OpenStruct.new
    billing_requests = Object.new
    brq_params = {}
    billing_requests.define_singleton_method(:create) do |opts|
      brq_params.merge!(opts[:params])
      billing_request
    end
    billing_request_flows = Object.new
    flow_params = {}
    billing_request_flows.define_singleton_method(:create) do |opts|
      flow_params.merge!(opts[:params])
      billing_request_flow
    end
    client = OpenStruct.new(billing_requests: billing_requests, billing_request_flows: billing_request_flows)

    GoCardlessPro::Client.stub :new, client do
      EventPaymentMethod::GoCardlessInstalment.call(order: order, event: event)
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
    event = create_event
    order = create_instalment_order(event)
    client, captured = stub_gocardless_schedule_client

    deliver_webhook(event.organisation, billing_request_event(order.gocardless_billing_request_id), client)

    assert_equal [1000, 1000, 1000], captured[:params][:instalments][:amounts]
    assert_equal 'monthly', captured[:params][:instalments][:interval_unit]
    assert order.reload.payment_completed?
    assert order.tickets.first.reload.payment_completed?
  end

  test 'fulfilled billing request webhook restores a deleted checkout' do
    event = create_event
    order = create_instalment_order(event)
    billing_request_id = order.gocardless_billing_request_id
    order.destroy
    client, = stub_gocardless_schedule_client

    deliver_webhook(event.organisation, billing_request_event(billing_request_id), client)

    restored = Order.find(order.id)
    assert restored
    assert restored.payment_completed?
    assert restored.tickets.first
  end
end
