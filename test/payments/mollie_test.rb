require_relative '../test_config'
require_relative '../helpers/checkout_webhook_helpers'

# Paying with Mollie, and its webhooks
class MolliePaymentsTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include CheckoutWebhookHelpers

  def create_mollie_event
    create_organisation(mollie_api_key: 'test_molliekey')
    create_event(prices: [10])
  end

  def stub_mollie_payment(id: 'tr_test', checkout_url: 'https://www.mollie.com/checkout/select-method/test', paid: true)
    payment = Object.new
    payment.define_singleton_method(:id) { id }
    payment.define_singleton_method(:checkout_url) { checkout_url }
    payment.define_singleton_method(:paid?) { paid }
    payment
  end

  def deliver_mollie_webhook(organisation, payment)
    Mollie::Payment.stub :get, payment do
      post "/o/#{organisation.slug}/mollie_webhook", id: payment.id
    end
  end

  def post_mollie_purchase(event, account)
    ticket_type = event.ticket_types.first
    header 'Accept', 'application/json'
    post "/e/#{event.slug}/purchase",
         ticketForm: { quantities: { ticket_type.id.to_s => '1' } },
         detailsForm: {
           payment_method: 'mollie',
           account: { name: account.name, email: account.email }
         }
  end

  test 'organisation with a mollie api key has a payment method' do
    create_organisation(stripe_pk: nil, stripe_sk: nil, mollie_api_key: 'test_molliekey')
    assert @organisation.payment_method?
  end

  test 'mollie api key must look like a live or test key' do
    organisation = FactoryBot.build(:organisation, stripe_pk: nil, stripe_sk: nil, mollie_api_key: 'not-a-key')
    refute organisation.valid?
    assert_includes organisation.errors[:mollie_api_key], 'must start with live_ or test_'
  end

  test 'mollie is available for fiat-currency events when an API key is set' do
    covers 'events/mollie-fiat-events@8e9a10'
    create_mollie_event
    pm = EventPaymentMethod.object('mollie')

    assert pm.available?(@event)
    @event.set(currency: 'EUR')
    assert pm.available?(@event)
    @event.set(currency: 'SEK')
    assert pm.available?(@event)
    @organisation.unset(:mollie_api_key)
    @event.organisation.reload
    refute pm.available?(@event)
  end

  test 'mollie checkout stores the payment id' do
    create_mollie_event
    order = create_incomplete_order(@event, value: 10)
    payment = stub_mollie_payment
    captured = {}

    Mollie::Payment.stub :create, lambda { |attrs|
      captured.replace(attrs)
      payment
    } do
      EventPaymentMethod::Mollie.call(order: order, event: @event)
    end

    assert_equal 'tr_test', order.reload.mollie_payment_id
    assert_equal 'tr_test', order.tickets.first.reload.mollie_payment_id
    assert_equal({ value: '10.00', currency: 'GBP' }, captured[:amount])
    assert_includes captured[:redirect_url], "order_id=#{order.public_id}"
    assert_includes captured[:redirect_url], 'success=true'
    assert_includes captured[:cancel_url], 'cancelled=true'
    assert_includes captured[:webhook_url], "/o/#{@organisation.slug}/mollie_webhook"
    assert_equal 'test_molliekey', captured[:api_key]
  end

  test 'mollie purchase creates an incomplete order then webhook issues the ticket' do
    covers 'events/mollie-hosted-checkout@8e7b2a', 'events/mollie-confirms-when-paid@4e04c7'
    create_mollie_event
    buyer = FactoryBot.create(:account)
    payment = stub_mollie_payment

    Mollie::Payment.stub :create, payment do
      post_mollie_purchase(@event, buyer)
    end

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal payment.checkout_url, body['redirect_url']

    order = @event.orders.find_by(mollie_payment_id: payment.id)
    assert order
    refute order.payment_completed?
    refute order.tickets.first.payment_completed?

    deliver_mollie_webhook(@organisation, payment)

    assert_equal 200, last_response.status
    assert order.reload.payment_completed?
    assert order.tickets.first.reload.payment_completed?
  end

  test 'paid mollie webhook restores a deleted checkout' do
    covers_route 'POST /o/:slug/mollie_webhook'
    create_mollie_event
    order = create_incomplete_order(@event, mollie_payment_id: "tr_#{SecureRandom.hex(4)}")
    payment_id = order.mollie_payment_id
    order.destroy

    deliver_mollie_webhook(@organisation, stub_mollie_payment(id: payment_id))

    restored = Order.find(order.id)
    assert restored
    assert restored.payment_completed?
    assert restored.tickets.first
    assert restored.tickets.first.payment_completed?
  end

  test 'mollie webhook for an unknown payment id does not call Mollie' do
    create_mollie_event

    Mollie::Payment.stub :get, ->(*) { raise 'Mollie::Payment.get should not be called' } do
      post "/o/#{@organisation.slug}/mollie_webhook", id: 'tr_unknown'
    end

    assert_equal 200, last_response.status
  end

  test 'unpaid mollie webhook does not complete the order' do
    covers 'events/mollie-confirms-when-paid@4e04c7'
    create_mollie_event
    order = create_incomplete_order(@event, mollie_payment_id: "tr_#{SecureRandom.hex(4)}")

    deliver_mollie_webhook(@organisation, stub_mollie_payment(id: order.mollie_payment_id, paid: false))

    assert_equal 200, last_response.status
    refute order.reload.payment_completed?
  end
end
