require_relative '../test_config'
require_relative '../helpers/orders_helpers'

# Orders and tickets found by their secret token, legacy ones by id, and editing ticketholder details
class OrderTokensTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include OrdersHelpers

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
end
