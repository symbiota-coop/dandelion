require_relative '../test_config'
require_relative '../helpers/bookings_helpers'

# Bookings that come to less than a payment provider takes (EventPaymentMethod#minimum_amount), which it would refuse
class BookingPaymentMinimumsTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include BookingsHelpers

  # A GoCardless client that records the payment requests it's asked for, or answers with error
  def fake_gocardless_checkout(requests, error: nil)
    billing_request = api_object(id: 'BRQ123', links: api_object(payment_request: 'PRQ123'))
    billing_requests = Object.new
    billing_requests.define_singleton_method(:create) do |opts|
      requests << opts[:params]
      raise error if error

      billing_request
    end
    flow = api_object(authorisation_url: 'https://pay.gocardless.com/test')
    billing_request_flows = Object.new
    billing_request_flows.define_singleton_method(:create) { |_opts| flow }
    api_object(billing_requests: billing_requests, billing_request_flows: billing_request_flows)
  end

  # A free event taking donations to its organisation, paid by GoCardless Instant Bank Pay, as in the booking that
  # GoCardless refused
  def create_gocardless_event(**attrs)
    create_organisation(gocardless_access_token: 'sandbox_token', gocardless_endpoint_secret: 'webhook_secret', gocardless_instant_bank_pay: true, gocardless_instalments: true)
    create_event(prices: [0], suggested_donation: 3, **attrs)
    refute @event.donations_to_dandelion?
  end

  def failed_purchase_emails(emails)
    emails.select { |email| email.subject_line.include?('error on') }
  end

  def error_message
    JSON.parse(last_response.body)['error']
  end

  test 'GoCardless refuses a booking under £1 before asking GoCardless, and takes one of £1' do
    covers 'organisations/payment-minimums@a59df4'
    create_gocardless_event
    requests = []

    emails = recorded_emails do
      GoCardlessPro::Client.stub(:new, fake_gocardless_checkout(requests)) do
        post_purchase(payment_method: 'gocardless_instant', ticket_form: { donation_amount: '0.5' })
      end
    end
    assert_equal 400, last_response.status
    assert_equal 'Payments with GoCardless must be at least £1. Choose another way to pay, or a higher price or donation.', error_message
    assert_empty requests
    assert_equal 0, Order.and(event_id: @event.id).count
    assert_empty failed_purchase_emails(emails)

    GoCardlessPro::Client.stub(:new, fake_gocardless_checkout(requests)) do
      post_purchase(payment_method: 'gocardless_instant', ticket_form: { donation_amount: '1' })
    end
    assert_equal 200, last_response.status
    assert_equal [100], (requests.map { |params| params[:payment_request][:amount] })
    assert_equal 'PRQ123', @event.orders.last.gocardless_payment_request_id
  end

  test 'GoCardless instalments need at least £1 for each instalment' do
    covers 'organisations/payment-minimums@a59df4'
    create_gocardless_event(gocardless_instalment_count: 3)
    requests = []

    GoCardlessPro::Client.stub(:new, fake_gocardless_checkout(requests)) do
      post_purchase(payment_method: 'gocardless_instalment', ticket_form: { donation_amount: '2.99' })
      assert_equal 400, last_response.status
      assert_equal 'Payments with GoCardless must be at least £3. Choose another way to pay, or a higher price or donation.', error_message
      assert_empty requests

      post_purchase(payment_method: 'gocardless_instalment', ticket_form: { donation_amount: '3' })
    end
    assert_equal 200, last_response.status
    assert_equal 1, requests.length
    assert_equal 3, @event.orders.last.total
  end

  test "Stripe refuses a booking under its currency's minimum, and takes one of it" do
    covers 'organisations/payment-minimums@a59df4'
    create_event(prices: [0], suggested_donation: 3)

    session_created = false
    Stripe::Checkout::Session.stub(:create, ->(*) { session_created = true }) do
      post_purchase(payment_method: 'stripe', ticket_form: { donation_amount: '0.29' })
    end
    assert_equal 400, last_response.status
    assert_equal 'Payments with Stripe must be at least £0.30. Choose another way to pay, or a higher price or donation.', error_message
    refute session_created
    assert_equal 0, Order.and(event_id: @event.id).count

    @event.set(currency: 'SEK')
    post_purchase(payment_method: 'stripe', ticket_form: { donation_amount: '2' })
    assert_equal 400, last_response.status
    assert_equal 'Payments with Stripe must be at least SEK 3. Choose another way to pay, or a higher price or donation.', error_message

    @event.set(currency: 'GBP')
    with_stubbed_stripe_session { post_purchase(payment_method: 'stripe', ticket_form: { donation_amount: '0.3' }) }
    assert_equal 200, last_response.status
    assert_equal 0.3, @event.orders.last.total
  end

  test 'credit that pays for all but less than the minimum is checked against what is left, and credit that pays for it all needs no payment' do
    # In the event's currency, so the credit isn't exchanged
    create_organisation(currency: 'GBP')
    create_event(prices: [10.2])
    buyer = FactoryBot.create(:account)
    # Credit is in whole units
    grant_credit(buyer, amount: 10)
    builder = ->(**args) { OrderBuilder.new(event: @event, buyer: { name: buyer.name, email: buyer.email }, signed_in_account: buyer, quantities: { @event.ticket_types.first.id.to_s => '1' }, payment_method: 'stripe', **args) }

    error = assert_raises(OrderBuilder::PaymentTooSmall) { with_stubbed_stripe_session { builder.call.call } }
    assert_includes error.message, '£0.30'
    assert_equal 0, Order.and(event_id: @event.id).count

    # Before credit, the booking comes to £10.20, so the minimum is checked once the credit is known
    grant_credit(buyer, amount: 1)
    builder.call.call
    order = @event.orders.last
    assert_equal 10.2, order.credit_applied
    assert order.payment_completed
  end

  test "GoCardless refusing an amount anyway doesn't send the organisation to its dashboard" do
    create_gocardless_event
    @event.set(suggested_donation: 5)
    amount_error = GoCardlessPro::ValidationError.new(
      'message' => 'Validation failed', 'request_id' => 'REQ123',
      'errors' => [{ 'field' => 'payment_request', 'message' => 'is lower than the minimum permitted amount', 'request_pointer' => '/billing_requests/payment_request/amount' }]
    )
    other_error = GoCardlessPro::ValidationError.new(
      'message' => 'Validation failed', 'errors' => [{ 'field' => 'currency', 'message' => 'is not supported', 'request_pointer' => '/billing_requests/payment_request/currency' }]
    )

    emails = recorded_emails do
      [amount_error, other_error].each do |error|
        GoCardlessPro::Client.stub(:new, fake_gocardless_checkout([], error: error)) do
          post_purchase(payment_method: 'gocardless_instant', ticket_form: { donation_amount: '5' })
        end
        assert_equal OrderBuilder::PaymentFailed::MESSAGE, error_message
      end
    end
    emails = failed_purchase_emails(emails)
    assert_equal 2, emails.length
    refute_includes emails.first.html, 'read-write access'
    assert_includes emails.first.html, 'lower than the minimum permitted amount'
    assert_includes emails.last.html, 'read-write access'
  end
end
