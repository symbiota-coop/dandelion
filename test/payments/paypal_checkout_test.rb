require_relative '../test_config'
require_relative '../helpers/checkout_webhook_helpers'

# Paying with PayPal through its API, with PayPal's HTTP answered by stubs: creating the PayPal order at checkout,
# capturing it once from the webhook or the return page, and refunding its capture
class PaymentsPaypalCheckoutTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include CheckoutWebhookHelpers

  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze

  setup do
    Paypal.token_cache.clear
  end

  # PayPal's API answers from stubs for the block (Paypal connects with Faraday's default adapter). The stubs answer
  # the token request with the client id the token is for; the block given stubs anything else. Yields each request
  def with_paypal_api(define_stubs)
    requests = []
    stubs = Faraday::Adapter::Test::Stubs.new do |stub|
      stub.post('/v1/oauth2/token') do |env|
        requests << env
        client_id = Base64.strict_decode64(env.request_headers['Authorization'].delete_prefix('Basic ')).split(':').first
        [200, JSON_HEADERS, { access_token: "token-for-#{client_id}", expires_in: 3600 }.to_json]
      end
      define_stubs.call(stub, requests)
    end
    Faraday.stub :default_adapter, :test do
      Faraday::Adapter::Test::Stubs.stub :new, stubs do
        yield requests
      end
    end
  end

  def paypal_order_json(id, status:, capture_id: nil, amount: nil, capture_amount: nil)
    {
      id: id,
      status: status,
      links: [{ rel: 'payer-action', href: "https://www.sandbox.paypal.com/checkoutnow?token=#{id}" }],
      purchase_units: [{
        amount: amount,
        payments: { captures: capture_id ? [{ id: capture_id, status: 'COMPLETED', amount: capture_amount }.compact] : [] }
      }.compact]
    }.to_json
  end

  # Completes order from a PayPal order PayPal says it captured capture_amount for, returning what was reported
  def complete_with_capture_amount(order, capture_amount)
    stubs = lambda do |stub, _requests|
      stub.get("/v2/checkout/orders/#{order.paypal_order_id}") do
        [200, JSON_HEADERS, paypal_order_json(order.paypal_order_id, status: 'COMPLETED', capture_id: 'CAPTURE', capture_amount: capture_amount)]
      end
    end
    reported = []
    ErrorReporting.stub(:capture_exception, ->(e, context: nil, **) { reported << [e, context] }) do
      with_paypal_api(stubs) { EventPaymentMethod::Paypal.complete_if_paid(order) }
    end
    reported
  end

  def requests_to(requests, method, path)
    requests.select { |env| env.method == method && env.url.path == path }
  end

  def create_paypal_organisation
    create_organisation(stripe_pk: nil, stripe_sk: nil, paypal_client_id: 'org_client', paypal_secret: 'org_secret')
  end

  def post_paypal_checkout(ticket_form: {}, buyer: FactoryBot.create(:account))
    header 'Accept', 'application/json'
    post "/e/#{@event.slug}/purchase",
         ticketForm: { quantities: { @event.ticket_types.first.id.to_s => '1' } }.merge(ticket_form),
         detailsForm: { payment_method: 'paypal', account: { name: buyer.name, email: buyer.email } }
  end

  # A PayPal order the buyer has approved, which PayPal captures (once) when asked: the stubs say how many times it was
  def approved_paypal_order_stubs(paypal_order_id, captures)
    lambda do |stub, requests|
      stub.get("/v2/checkout/orders/#{paypal_order_id}") do |env|
        requests << env
        [200, JSON_HEADERS, captures.empty? ? paypal_order_json(paypal_order_id, status: 'APPROVED') : paypal_order_json(paypal_order_id, status: 'COMPLETED', capture_id: 'CAPTURE')]
      end
      stub.post("/v2/checkout/orders/#{paypal_order_id}/capture") do |env|
        requests << env
        captures << env
        [201, JSON_HEADERS, paypal_order_json(paypal_order_id, status: 'COMPLETED', capture_id: 'CAPTURE')]
      end
    end
  end

  def create_paid_paypal_order(value: 10, tickets: 1)
    order = Order.create!(event: @event, account: FactoryBot.create(:account), value: value, currency: @event.currency,
                          payment_completed: true, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}", paypal_capture_id: 'CAPTURE')
    tickets.times do
      order.tickets.create!(event: @event, account: order.account, ticket_type: @event.ticket_types.first, payment_completed: true,
                            paypal_order_id: order.paypal_order_id, paypal_capture_id: 'CAPTURE')
    end
    order
  end

  # Checkout

  test 'checkout asks PayPal for the order total, discounted and with its donation, in its currency, with its organisation credentials' do
    create_paypal_organisation
    FactoryBot.create(:organisation, stripe_pk: nil, stripe_sk: nil, paypal_client_id: 'other_client', paypal_secret: 'other_secret')
    create_event(prices: [12.5], currency: 'EUR', donations_to_organisation: true, suggested_donation: 5)
    @event.discount_codes.create!(code: 'TWENTY', percentage_discount: 20)

    stubs = lambda do |stub, requests|
      stub.post('/v2/checkout/orders') do |env|
        requests << env
        [201, JSON_HEADERS, paypal_order_json('PAYPAL-NEW', status: 'PAYER_ACTION_REQUIRED')]
      end
    end
    with_paypal_api(stubs) do |requests|
      post_paypal_checkout(ticket_form: { quantities: { @event.ticket_types.first.id.to_s => '2' }, applied_discount_code: 'TWENTY', donation_amount: '3.33' })

      assert_equal 200, last_response.status
      assert_equal 'https://www.sandbox.paypal.com/checkoutnow?token=PAYPAL-NEW', JSON.parse(last_response.body)['redirect_url']
      order = @event.orders.find_by(paypal_order_id: 'PAYPAL-NEW')
      refute order.payment_completed?
      assert_equal 23.33, order.value
      assert_equal(%w[PAYPAL-NEW PAYPAL-NEW], order.tickets.map(&:paypal_order_id))

      token_request = requests_to(requests, :post, '/v1/oauth2/token').sole
      assert_equal "Basic #{Base64.strict_encode64('org_client:org_secret')}", token_request.request_headers['Authorization']
      create_request = requests_to(requests, :post, '/v2/checkout/orders').sole
      assert_equal Paypal::SANDBOX_HOST, "#{create_request.url.scheme}://#{create_request.url.host}"
      assert_equal 'Bearer token-for-org_client', create_request.request_headers['Authorization']
      assert_equal "dandelion-order-#{order.id}", create_request.request_headers['PayPal-Request-Id']
      purchase_unit = JSON.parse(create_request.request_body)['purchase_units'].sole
      assert_equal({ 'currency_code' => 'EUR', 'value' => '23.33' }, purchase_unit['amount'])
      assert_equal order.id.to_s, purchase_unit['custom_id']
    end
  end

  test 'an error from PayPal at checkout leaves no order or tickets behind' do
    create_paypal_organisation
    create_event(prices: [10])
    stubs = lambda do |stub, _requests|
      stub.post('/v2/checkout/orders') { [500, JSON_HEADERS, { name: 'INTERNAL_SERVER_ERROR', message: 'An internal server error occurred' }.to_json] }
    end

    emails = with_paypal_api(stubs) do
      recorded_emails { post_paypal_checkout }
    end

    assert_equal 400, last_response.status
    assert_equal OrderBuilder::PaymentFailed::MESSAGE, JSON.parse(last_response.body)['error']
    assert_equal 0, @event.orders.count
    assert_equal 0, @event.tickets.count
    refute @event.reload.locked
    # The organisation is told what PayPal said
    failed = emails.find { |email| email.subject_line == "PayPal error on #{@event.name}" }
    assert_includes failed.html, 'An internal server error occurred (HTTP 500)'
  end

  test 'PayPal refusing the organisation credentials at checkout locks the event and leaves no order' do
    create_paypal_organisation
    create_event(prices: [10])
    stubs = lambda do |stub, _requests|
      stub.post('/v2/checkout/orders') { [401, JSON_HEADERS, { error: 'invalid_token', error_description: 'Token signature verification failed' }.to_json] }
    end

    with_paypal_api(stubs) { post_paypal_checkout }

    assert_equal 400, last_response.status
    assert_equal 0, @event.orders.count
    assert_equal 0, @event.tickets.count
    @event.reload
    assert @event.locked
    assert_equal 'PayPal', @event.locked_error_provider
    assert_equal 'Token signature verification failed (HTTP 401)', @event.locked_error
  end

  test 'a PayPal order without an approval link, or PayPal being unreachable, leaves no order behind' do
    create_paypal_organisation
    create_event(prices: [10])
    no_link = lambda do |stub, _requests|
      stub.post('/v2/checkout/orders') { [201, JSON_HEADERS, { id: 'PAYPAL-NO-LINK', status: 'CREATED', links: [] }.to_json] }
    end
    unreachable = lambda do |stub, _requests|
      stub.post('/v2/checkout/orders') { raise Faraday::ConnectionFailed, 'Connection refused' }
    end

    [no_link, unreachable].each do |stubs|
      with_paypal_api(stubs) { post_paypal_checkout }

      assert_equal 400, last_response.status
      assert_equal OrderBuilder::PaymentFailed::MESSAGE, JSON.parse(last_response.body)['error']
      assert_equal 0, @event.orders.count
      assert_equal 0, @event.tickets.count
      refute Order.unscoped.find_by(paypal_order_id: 'PAYPAL-NO-LINK')
    end
  end

  # Capturing

  test 'an order the webhook and the return page both confirm is captured and completed once' do
    covers 'events/paypal-capture-on-return-or-webhook@1d2561'
    create_paypal_organisation
    create_event(prices: [10])
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    captures = []

    with_paypal_api(approved_paypal_order_stubs(order.paypal_order_id, captures)) do
      deliver_paypal_webhook(@organisation, event_type: 'CHECKOUT.ORDER.APPROVED', resource: { id: order.paypal_order_id })
      assert_equal 200, last_response.status
      assert order.reload.payment_completed?
      assert_equal 1, send_tickets_jobs(order, by: :paypal_order_id).count

      # The buyer comes back from PayPal, and PayPal sends its capture webhook too
      get "/e/#{@event.slug}?success=true&order_id=#{order.public_id}"
      assert_includes last_response.body, 'Thanks for booking'
      deliver_paypal_webhook(@organisation, event_type: 'PAYMENT.CAPTURE.COMPLETED',
                                            resource: { id: 'CAPTURE', supplementary_data: { related_ids: { order_id: order.paypal_order_id } } })
      assert_equal 200, last_response.status
    end

    assert_equal 1, send_tickets_jobs(order, by: :paypal_order_id).count
    assert_equal 1, captures.size
    assert_equal "dandelion-capture-#{order.id}", captures.first.request_headers['PayPal-Request-Id']
    assert_equal 'CAPTURE', order.reload.paypal_capture_id
  end

  test 'two requests completing the same PayPal order at once send its tickets once' do
    create_paypal_organisation
    create_event(prices: [10])
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    # Both loaded before either completes it, as the webhook and the return page would be
    from_webhook = Order.find(order.id)
    from_return_page = Order.find(order.id)
    captures = []

    with_paypal_api(approved_paypal_order_stubs(order.paypal_order_id, captures)) do
      EventPaymentMethod::Paypal.complete_if_paid(from_webhook)
      EventPaymentMethod::Paypal.complete_if_paid(from_return_page)
    end

    assert_equal 1, send_tickets_jobs(order, by: :paypal_order_id).count
    assert order.reload.payment_completed?
    assert order.tickets.first.payment_completed?
  end

  test 'a PayPal order captured already completes the order without capturing it again' do
    covers_route 'GET /e/:slug/orders/:order_id/payment_completed'
    create_paypal_organisation
    create_event(prices: [10])
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    stubs = lambda do |stub, requests|
      stub.get("/v2/checkout/orders/#{order.paypal_order_id}") do |env|
        requests << env
        [200, JSON_HEADERS, paypal_order_json(order.paypal_order_id, status: 'COMPLETED', capture_id: 'CAPTURE')]
      end
    end

    with_paypal_api(stubs) do |requests|
      get "/e/#{@event.slug}/orders/#{order.public_id}/payment_completed"
      assert JSON.parse(last_response.body)['payment_completed']
      assert_empty requests_to(requests, :post, "/v2/checkout/orders/#{order.paypal_order_id}/capture")
      # The token is fetched once and kept for later requests
      get "/e/#{@event.slug}/orders/#{order.public_id}/payment_completed"
      assert_equal 1, requests_to(requests, :post, '/v1/oauth2/token').size
    end

    assert order.reload.payment_completed?
    assert_equal 'CAPTURE', order.paypal_capture_id
    assert_equal 'CAPTURE', order.tickets.first.paypal_capture_id
  end

  test 'a capture PayPal refuses completes the order only if PayPal then says it was captured' do
    create_paypal_organisation
    create_event(prices: [10])
    [['COMPLETED', true], ['APPROVED', false]].each do |status_after, completes|
      order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
      gets = 0
      stubs = lambda do |stub, _requests|
        stub.get("/v2/checkout/orders/#{order.paypal_order_id}") do
          gets += 1
          [200, JSON_HEADERS, paypal_order_json(order.paypal_order_id, status: gets == 1 ? 'APPROVED' : status_after, capture_id: ('CAPTURE' if status_after == 'COMPLETED' && gets > 1))]
        end
        stub.post("/v2/checkout/orders/#{order.paypal_order_id}/capture") do
          [422, JSON_HEADERS, { name: 'UNPROCESSABLE_ENTITY', details: [{ issue: 'ORDER_ALREADY_CAPTURED' }] }.to_json]
        end
      end

      with_paypal_api(stubs) { EventPaymentMethod::Paypal.complete_if_paid(order) }

      assert_equal 2, gets
      assert_equal completes, order.reload.payment_completed?
    end
  end

  test 'a capture for the order total in its currency completes the order and reports nothing' do
    create_paypal_organisation
    create_event(prices: [10], currency: 'EUR')
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")

    reported = complete_with_capture_amount(order, { currency_code: 'EUR', value: '10.00' })

    assert order.reload.payment_completed?
    assert_empty reported
  end

  test 'a capture for a different amount or in a different currency still completes the order, and is reported once' do
    create_paypal_organisation
    create_event(prices: [23.33], currency: 'EUR')
    [[{ currency_code: 'EUR', value: '2.33' }, '2.33', 'EUR'], [{ currency_code: 'USD', value: '23.33' }, '23.33', 'USD']].each do |capture_amount, actual_amount, actual_currency|
      order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")

      reported = complete_with_capture_amount(order, capture_amount)

      assert order.reload.payment_completed?
      assert_equal 'CAPTURE', order.paypal_capture_id
      error, context = reported.sole
      assert_kind_of EventPaymentMethod::Paypal::AmountMismatch, error
      assert_equal({ order_id: order.id.to_s, paypal_order_id: order.paypal_order_id, expected_amount: '23.33', expected_currency: 'EUR',
                     actual_amount: actual_amount, actual_currency: actual_currency }, context)
      # Completed, so checking again reports nothing more
      assert_empty complete_with_capture_amount(order, capture_amount)
    end
  end

  test 'a capture for an amount PayPal gives without decimals matches the order total' do
    create_paypal_organisation
    create_event(prices: [10], currency: 'EUR')
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")

    assert_empty complete_with_capture_amount(order, { currency_code: 'EUR', value: '10' })
    assert order.reload.payment_completed?
  end

  test 'a capture refused for the organisation credentials is raised and completes nothing' do
    create_paypal_organisation
    create_event(prices: [10])
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    stubs = lambda do |stub, _requests|
      stub.get("/v2/checkout/orders/#{order.paypal_order_id}") { [200, JSON_HEADERS, paypal_order_json(order.paypal_order_id, status: 'APPROVED')] }
      stub.post("/v2/checkout/orders/#{order.paypal_order_id}/capture") { [403, JSON_HEADERS, { name: 'NOT_AUTHORIZED', message: 'Authorization failed' }.to_json] }
    end

    error = with_paypal_api(stubs) do
      assert_raises(Paypal::RequestError) { EventPaymentMethod::Paypal.complete_if_paid(order) }
    end

    assert_equal 403, error.status
    assert_equal 'Authorization failed (HTTP 403)', error.message
    refute order.reload.payment_completed?
  end

  # Webhooks

  test 'a forged webhook saying a payment was captured completes nothing unless PayPal says so' do
    covers_route 'POST /o/:slug/paypal_webhook'
    create_paypal_organisation
    create_event(prices: [10])
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    stubs = lambda do |stub, requests|
      stub.get("/v2/checkout/orders/#{order.paypal_order_id}") do |env|
        requests << env
        [200, JSON_HEADERS, paypal_order_json(order.paypal_order_id, status: 'PAYER_ACTION_REQUIRED')]
      end
    end

    with_paypal_api(stubs) do |requests|
      deliver_paypal_webhook(@organisation, event_type: 'PAYMENT.CAPTURE.COMPLETED',
                                            resource: { id: 'FORGED', status: 'COMPLETED', supplementary_data: { related_ids: { order_id: order.paypal_order_id } } })

      assert_equal 200, last_response.status
      # Checked with PayPal, as the organisation, and not captured
      assert_equal 'Bearer token-for-org_client', requests_to(requests, :get, "/v2/checkout/orders/#{order.paypal_order_id}").sole.request_headers['Authorization']
      assert_empty requests_to(requests, :post, "/v2/checkout/orders/#{order.paypal_order_id}/capture")
    end
    order.reload
    refute order.payment_completed?
    assert_nil order.paypal_capture_id
  end

  test 'a webhook for an order PayPal does not know completes nothing' do
    create_paypal_organisation
    create_event(prices: [10])
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    stubs = lambda do |stub, _requests|
      stub.get("/v2/checkout/orders/#{order.paypal_order_id}") { [404, JSON_HEADERS, { name: 'RESOURCE_NOT_FOUND', message: 'The specified resource does not exist.' }.to_json] }
    end

    with_paypal_api(stubs) do
      deliver_paypal_webhook(@organisation, event_type: 'CHECKOUT.ORDER.APPROVED', resource: { id: order.paypal_order_id })
    end

    assert_equal 200, last_response.status
    refute order.reload.payment_completed?
  end

  test "a webhook sent to another organisation, malformed or of another type completes nothing and doesn't call PayPal" do
    create_paypal_organisation
    create_event(prices: [10])
    order = create_incomplete_order(@event, paypal_order_id: "PAYPAL-#{SecureRandom.hex(4)}")
    other = FactoryBot.create(:organisation, stripe_pk: nil, stripe_sk: nil, paypal_client_id: 'other_client', paypal_secret: 'other_secret')
    without_paypal = FactoryBot.create(:organisation, stripe_pk: nil, stripe_sk: nil)
    approved = { event_type: 'CHECKOUT.ORDER.APPROVED', resource: { id: order.paypal_order_id } }

    Paypal.stub :new, ->(*) { raise 'Paypal.new should not be called' } do
      deliver_paypal_webhook(other, approved)
      assert_equal 200, last_response.status
      deliver_paypal_webhook(without_paypal, approved)
      assert_equal 200, last_response.status
      deliver_paypal_webhook(@organisation, '{not json')
      assert_equal 200, last_response.status
      deliver_paypal_webhook(@organisation, event_type: 'PAYMENT.CAPTURE.REFUNDED', resource: { id: order.paypal_order_id })
      assert_equal 200, last_response.status
    end

    refute order.reload.payment_completed?
  end

  # Refunds

  test 'refunding a PayPal order refunds its whole capture as the organisation and emails the buyer' do
    covers 'events/refunds-to-original-method@119ce8', 'events/refund-confirmation-email@e7eb67'
    create_paypal_organisation
    create_event(prices: [10], currency: 'EUR')
    order = create_paid_paypal_order(value: 20, tickets: 2)
    stubs = lambda do |stub, requests|
      stub.post('/v2/payments/captures/CAPTURE/refund') do |env|
        requests << env
        [201, JSON_HEADERS, { id: 'REFUND', status: 'COMPLETED' }.to_json]
      end
    end

    with_paypal_api(stubs) do |requests|
      emails = recorded_emails { order.refund }

      refund_request = requests_to(requests, :post, '/v2/payments/captures/CAPTURE/refund').sole
      assert_equal 'Bearer token-for-org_client', refund_request.request_headers['Authorization']
      assert_equal({ 'amount' => { 'currency_code' => 'EUR', 'value' => '20.00' } }, JSON.parse(refund_request.request_body))
      refund_email = emails.sole
      assert_equal [order.account.email], refund_email.recipients
      assert_equal "Your refund for #{@event.name}", refund_email.subject_line
      assert_includes refund_email.html, 'A refund of €20 has been issued'
      assert_includes refund_email.html, 'via PayPal'
    end
  end

  test "refunding one ticket of a PayPal order refunds just that ticket's price" do
    covers 'events/refund-ticket-own-price@985cff'
    create_paypal_organisation
    create_event(prices: [10])
    order = create_paid_paypal_order(value: 20, tickets: 2)
    stubs = lambda do |stub, requests|
      stub.post('/v2/payments/captures/CAPTURE/refund') do |env|
        requests << env
        [201, JSON_HEADERS, { id: 'REFUND', status: 'COMPLETED' }.to_json]
      end
    end

    with_paypal_api(stubs) do |requests|
      emails = recorded_emails { order.tickets.first.refund }

      refund_request = requests_to(requests, :post, '/v2/payments/captures/CAPTURE/refund').sole
      assert_equal({ 'currency_code' => 'GBP', 'value' => '10.00' }, JSON.parse(refund_request.request_body)['amount'])
      assert_includes emails.sole.html, 'A refund of £10 has been issued'
    end
  end

  test 'a refund PayPal refuses emails the event contacts the error, not the buyer a confirmation' do
    covers 'events/refund-failure-email@176a81', 'events/refund-confirmation-email@e7eb67'
    create_paypal_organisation
    create_event(prices: [10])
    order = create_paid_paypal_order
    stubs = lambda do |stub, _requests|
      stub.post('/v2/payments/captures/CAPTURE/refund') do
        [422, JSON_HEADERS, { name: 'UNPROCESSABLE_ENTITY', message: 'The requested action could not be performed', details: [{ issue: 'CAPTURE_FULLY_REFUNDED', description: 'The capture has already been fully refunded' }] }.to_json]
      end
    end

    emails = with_paypal_api(stubs) do
      recorded_emails { order.refund }
    end

    failed = emails.sole
    assert_equal "Refund failed: #{order.account.name} in #{@event.name}", failed.subject_line
    assert_includes failed.recipients, @account.email
    refute_includes failed.recipients, order.account.email
    assert_includes failed.html, 'The capture has already been fully refunded'
  end
end
