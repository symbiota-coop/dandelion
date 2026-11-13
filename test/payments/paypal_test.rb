require_relative '../test_config'
require_relative '../helpers/checkout_webhook_helpers'

# Paying with PayPal, its webhooks and its return page
class PaypalPaymentsTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include CheckoutWebhookHelpers

  def create_paypal_event
    create_organisation(paypal_client_id: 'paypal_client', paypal_secret: 'paypal_secret')
    create_event(prices: [10])
  end

  def stub_paypal_order(id: 'PAYPAL-ORDER', approve_url: 'https://www.paypal.com/checkoutnow?token=test', status: 'CREATED', capture_id: nil)
    {
      'id' => id,
      'status' => status,
      'links' => [{ 'rel' => 'payer-action', 'href' => approve_url }],
      'purchase_units' => [{
        'payments' => {
          'captures' => capture_id ? [{ 'id' => capture_id, 'status' => 'COMPLETED' }] : []
        }
      }]
    }
  end

  def stub_paypal_client(create: nil, get: nil, capture: nil)
    client = Object.new
    client.define_singleton_method(:create_order) { |**| create }
    client.define_singleton_method(:get_order) { |_| get.respond_to?(:call) ? get.call : get }
    client.define_singleton_method(:capture_order) { |*| capture.respond_to?(:call) ? capture.call : capture }
    client
  end

  def deliver_paypal_event(organisation, event_type:, order_id: nil, capture_id: nil)
    resource = { 'id' => order_id }
    if event_type == 'PAYMENT.CAPTURE.COMPLETED'
      resource = {
        'id' => capture_id || 'CAPTURE',
        'supplementary_data' => { 'related_ids' => { 'order_id' => order_id } }
      }
    end
    deliver_paypal_webhook(organisation, { event_type: event_type, resource: resource })
  end

  def post_paypal_purchase(event, account)
    ticket_type = event.ticket_types.first
    header 'Accept', 'application/json'
    post "/e/#{event.slug}/purchase",
         ticketForm: { quantities: { ticket_type.id.to_s => '1' } },
         detailsForm: {
           payment_method: 'paypal',
           account: { name: account.name, email: account.email }
         }
  end

  test 'paypal error message includes oauth fields' do
    assert_equal 'Client Authentication failed (HTTP 401)',
                 Paypal.error_message({ 'error' => 'invalid_client', 'error_description' => 'Client Authentication failed' }, status: 401)
  end

  test 'paypal error message includes order details' do
    assert_equal 'Request is not well-formed: Invalid description (HTTP 400)',
                 Paypal.error_message(
                   { 'name' => 'INVALID_REQUEST', 'message' => 'Request is not well-formed', 'details' => [{ 'description' => 'Invalid description' }] },
                   status: 400
                 )
  end

  test 'organisation with paypal credentials has a payment method' do
    create_organisation(stripe_pk: nil, stripe_sk: nil, paypal_client_id: 'paypal_client', paypal_secret: 'paypal_secret')
    assert @organisation.payment_method?
  end

  test 'paypal client id and secret must be set together' do
    organisation = FactoryBot.build(:organisation, stripe_pk: nil, stripe_sk: nil, paypal_client_id: 'paypal_client')
    refute organisation.valid?
    assert_includes organisation.errors[:paypal_secret], 'must be present if PayPal client ID is present'
  end

  test 'paypal is available for fiat-currency events when credentials are set' do
    covers 'events/paypal-fiat-events@e7236d'
    create_paypal_event
    pm = EventPaymentMethod.object('paypal')

    assert pm.available?(@event)
    @event.set(currency: 'EUR')
    assert pm.available?(@event)
    @event.set(currency: 'SEK')
    assert pm.available?(@event)
    @organisation.unset(:paypal_secret)
    @event.organisation.reload
    refute pm.available?(@event)
  end

  test 'mollie and paypal are not offered on crypto-currency events' do
    covers 'events/mollie-fiat-events@8e9a10', 'events/paypal-fiat-events@e7236d'
    create_organisation(mollie_api_key: 'test_molliekey', paypal_client_id: 'paypal_client', paypal_secret: 'paypal_secret')
    create_event(prices: [10])
    mollie = EventPaymentMethod.object('mollie')
    paypal = EventPaymentMethod.object('paypal')
    assert mollie.available?(@event)
    assert paypal.available?(@event)

    @event.set(currency: EVM_CURRENCIES.first)
    refute mollie.available?(@event)
    refute paypal.available?(@event)
  end

  test 'paypal checkout stores the order id' do
    create_paypal_event
    order = create_incomplete_order(@event, value: 10)
    created = stub_paypal_order
    captured = {}
    client = stub_paypal_client(create: created)
    client.define_singleton_method(:create_order) do |**attrs|
      captured.replace(attrs)
      created
    end

    Paypal.stub :new, client do
      EventPaymentMethod::Paypal.call(order: order, event: @event)
    end

    assert_equal 'PAYPAL-ORDER', order.reload.paypal_order_id
    assert_equal 'PAYPAL-ORDER', order.tickets.first.reload.paypal_order_id
    assert_equal 10, captured[:amount]
    assert_equal 'GBP', captured[:currency]
    assert_includes captured[:return_url], "order_id=#{order.public_id}"
    assert_includes captured[:return_url], 'success=true'
    assert_includes captured[:cancel_url], 'cancelled=true'
    assert_equal order.id.to_s, captured[:custom_id]
  end

  test 'paypal purchase creates an incomplete order then webhook issues the ticket' do
    covers 'events/paypal-approve-on-paypal@61b06f', 'events/paypal-capture-on-return-or-webhook@1d2561'
    create_paypal_event
    buyer = FactoryBot.create(:account)
    created = stub_paypal_order
    approved = stub_paypal_order(status: 'APPROVED')
    captured = stub_paypal_order(status: 'COMPLETED', capture_id: 'CAPTURE')
    client = stub_paypal_client(create: created, get: approved, capture: captured)

    Paypal.stub :new, client do
      post_paypal_purchase(@event, buyer)
    end

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal created.dig('links', 0, 'href'), body['redirect_url']

    order = @event.orders.find_by(paypal_order_id: created['id'])
    assert order
    refute order.payment_completed?
    refute order.tickets.first.payment_completed?

    Paypal.stub :new, client do
      deliver_paypal_event(@organisation, event_type: 'CHECKOUT.ORDER.APPROVED', order_id: created['id'])
    end

    assert_equal 200, last_response.status
    assert order.reload.payment_completed?
    assert order.tickets.first.reload.payment_completed?
    assert_equal 'CAPTURE', order.paypal_capture_id
    assert_equal 'CAPTURE', order.tickets.first.paypal_capture_id
  end

  test 'paid paypal webhook restores a deleted checkout' do
    create_paypal_event
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    paypal_order_id = order.paypal_order_id
    order.destroy
    client = stub_paypal_client(get: stub_paypal_order(id: paypal_order_id, status: 'COMPLETED', capture_id: 'CAPTURE'))

    Paypal.stub :new, client do
      deliver_paypal_event(@organisation, event_type: 'PAYMENT.CAPTURE.COMPLETED', order_id: paypal_order_id)
    end

    restored = Order.find(order.id)
    assert restored
    assert restored.payment_completed?
    assert restored.tickets.first
    assert restored.tickets.first.payment_completed?
    assert_equal 'CAPTURE', restored.paypal_capture_id
  end

  test 'paypal webhook for an unknown order id does not call PayPal' do
    create_paypal_event

    Paypal.stub :new, ->(*) { raise 'Paypal.new should not be called' } do
      deliver_paypal_event(@organisation, event_type: 'CHECKOUT.ORDER.APPROVED', order_id: 'PAYPAL-unknown')
    end

    assert_equal 200, last_response.status
  end

  test 'unapproved paypal webhook does not complete the order' do
    create_paypal_event
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    client = stub_paypal_client(get: stub_paypal_order(id: order.paypal_order_id, status: 'PAYER_ACTION_REQUIRED'))

    Paypal.stub :new, client do
      deliver_paypal_event(@organisation, event_type: 'CHECKOUT.ORDER.APPROVED', order_id: order.paypal_order_id)
    end

    assert_equal 200, last_response.status
    refute order.reload.payment_completed?
  end

  test 'paypal return to success page captures and completes the order' do
    covers 'events/paypal-capture-on-return-or-webhook@1d2561'
    create_paypal_event
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    approved = stub_paypal_order(id: order.paypal_order_id, status: 'APPROVED')
    captured = stub_paypal_order(id: order.paypal_order_id, status: 'COMPLETED', capture_id: 'CAPTURE')
    client = stub_paypal_client(get: approved, capture: captured)

    Paypal.stub :new, client do
      get "/e/#{@event.slug}?success=true&order_id=#{order.public_id}"
    end

    assert_equal 200, last_response.status
    assert order.reload.payment_completed?
    assert_equal 'CAPTURE', order.paypal_capture_id
    assert_includes last_response.body, 'Thanks for booking'
    refute_includes last_response.body, 'Confirming your payment'
  end

  test 'paypal return to success page does not complete an unapproved order' do
    create_paypal_event
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    client = stub_paypal_client(get: stub_paypal_order(id: order.paypal_order_id, status: 'PAYER_ACTION_REQUIRED'))

    Paypal.stub :new, client do
      get "/e/#{@event.slug}?success=true&order_id=#{order.public_id}"
    end

    assert_equal 200, last_response.status
    refute order.reload.payment_completed?
    assert_includes last_response.body, 'Confirming your payment'
    refute_includes last_response.body, 'Thanks for booking'
  end

  test 'paypal payment_completed poll captures an approved order' do
    create_paypal_event
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    approved = stub_paypal_order(id: order.paypal_order_id, status: 'APPROVED')
    captured = stub_paypal_order(id: order.paypal_order_id, status: 'COMPLETED', capture_id: 'CAPTURE')
    client = stub_paypal_client(get: approved, capture: captured)

    Paypal.stub :new, client do
      get "/e/#{@event.slug}/orders/#{order.public_id}/payment_completed"
    end

    assert_equal 200, last_response.status
    assert JSON.parse(last_response.body)['payment_completed']
    assert order.reload.payment_completed?
    assert_equal 'CAPTURE', order.paypal_capture_id
  end

  test 'paypal return to success page still shows the pending card if PayPal errors' do
    create_paypal_event
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    client = stub_paypal_client(get: -> { raise Paypal::RequestError.new('PayPal request failed', status: 500) })

    Paypal.stub :new, client do
      get "/e/#{@event.slug}?success=true&order_id=#{order.public_id}"
    end

    assert_equal 200, last_response.status
    refute order.reload.payment_completed?
    assert_includes last_response.body, 'Confirming your payment'
  end

  test 'create_paypal_webhook_if_necessary registers the webhook in production' do
    covers 'events/paypal-capture-on-return-or-webhook@1d2561'
    create_paypal_event
    created = {}
    client = stub_paypal_client
    client.define_singleton_method(:list_webhooks) { { 'webhooks' => [] } }
    client.define_singleton_method(:create_webhook) do |**attrs|
      created.replace(attrs)
      { 'id' => 'WH' }
    end

    Padrino.stub :env, :production do
      Paypal.stub :new, client do
        @organisation.create_paypal_webhook_if_necessary
      end
    end

    assert_equal "#{ENV['BASE_URI']}/o/#{@organisation.slug}/paypal_webhook", created[:url]
  end

  test 'create_paypal_webhook_if_necessary does not create the webhook when it already exists' do
    create_paypal_event
    created = false
    url = @organisation.paypal_webhook_url
    client = stub_paypal_client
    client.define_singleton_method(:list_webhooks) do
      { 'webhooks' => [{
        'id' => 'WH',
        'url' => url,
        'event_types' => Paypal::WEBHOOK_EVENT_TYPES.map { |name| { 'name' => name } }
      }] }
    end
    client.define_singleton_method(:create_webhook) { |*| created = true }

    Padrino.stub :env, :production do
      Paypal.stub :new, client do
        @organisation.create_paypal_webhook_if_necessary
      end
    end

    refute created
  end

  test 'create_paypal_webhook_if_necessary does not call PayPal outside production' do
    create_paypal_event

    Paypal.stub :new, ->(*) { raise 'Paypal.new should not be called' } do
      @organisation.create_paypal_webhook_if_necessary
    end
  end
end
