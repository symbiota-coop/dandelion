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

  test 'public_id is the token, falling back to the mongo id for legacy orders' do
    create_complete_order
    assert_equal @order.token, @order.public_id

    make_legacy_order
    assert_nil @order.token
    assert_equal @order.id.to_s, @order.public_id
    assert_nil @order.reload.token
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

  def ticketholder_path(order_ref, action)
    "/events/#{@event.id}/orders/#{order_ref}/ticketholders/#{@ticket.id}/#{action}"
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
end
