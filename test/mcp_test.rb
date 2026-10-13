require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'ostruct'

class McpTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def mcp_post(body, headers: {})
    header 'Content-Type', 'application/json'
    header 'Accept', 'application/json, text/event-stream'
    headers.each { |key, value| header key, value }
    post '/mcp', body.to_json
  end

  def mcp_rpc(method, params: {}, headers: {}, id: 1)
    mcp_post({ jsonrpc: '2.0', id: id, method: method, params: params }, headers: headers)
    JSON.parse(last_response.body)
  end

  def mcp_tool_call(name, arguments: {}, headers: {})
    mcp_rpc('tools/call', params: { name: name, arguments: arguments }, headers: headers)
  end

  def tool_text(rpc)
    rpc.dig('result', 'content', 0, 'text')
  end

  def create_event_with_order_and_ticket
    @attendee = FactoryBot.create(:account, name: 'Ada Lovelace')
    create_event(prices: [0])
    @order = @event.orders.create!(
      account: @attendee,
      currency: @event.currency,
      value: 0,
      payment_completed: true,
      original_description: 'MCP test order',
      via: 'newsletter'
    )
    @ticket = @event.tickets.create!(
      account: @attendee,
      order: @order,
      ticket_type: @event.ticket_types.first,
      payment_completed: true
    )
  end

  test 'public tools remain available without authentication' do
    rpc = mcp_tool_call('get_trending_events_tool', arguments: { limit: 1 })

    assert_equal 200, last_response.status
    assert rpc.dig('result', 'content')
    refute rpc.dig('result', 'isError')
  end

  test 'get_me_tool requires authentication' do
    rpc = mcp_tool_call('get_me_tool')

    assert_equal 200, last_response.status
    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), 'Authentication required'
  end

  test 'get_me_tool returns the authenticated account' do
    account = FactoryBot.create(:account)

    rpc = mcp_tool_call('get_me_tool', headers: { 'Authorization' => "Bearer #{account.api_key}" })
    payload = JSON.parse(tool_text(rpc))

    assert_equal 200, last_response.status
    refute rpc.dig('result', 'isError')
    assert_equal account.id.to_s, payload['id']
    assert_equal account.name, payload['name']
    assert_equal account.username, payload['username']
    assert_equal account.email, payload['email']
    assert_equal "#{ENV['BASE_URI']}/u/#{account.username}", payload['url']
  end

  test 'invalid bearer token is rejected' do
    mcp_tool_call('get_me_tool', headers: { 'Authorization' => 'Bearer not-a-real-key' })

    assert_equal 401, last_response.status
    assert_equal 'Bearer', last_response['WWW-Authenticate']
    assert_equal 'invalid_token', JSON.parse(last_response.body)['error']
  end

  test 'event order and ticket tools require authentication' do
    %w[get_event_orders_tool get_event_tickets_tool get_organisation_events_tool get_organisation_followers_tool].each do |name|
      rpc = mcp_tool_call(name, arguments: { slug: 'example' })

      assert_equal 200, last_response.status
      assert rpc.dig('result', 'isError')
      assert_includes tool_text(rpc), 'Authentication required'
    end
  end

  test 'event admin can query orders and tickets' do
    create_event_with_order_and_ticket
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    orders_rpc = mcp_tool_call('get_event_orders_tool', arguments: { slug: @event.slug }, headers: headers)
    orders = JSON.parse(tool_text(orders_rpc))

    assert_equal 200, last_response.status
    refute orders_rpc.dig('result', 'isError')
    assert_equal 1, orders.length
    assert_equal @order.id.to_s, orders.first['id']
    assert_equal @attendee.name, orders.first['name']
    assert_equal @attendee.email, orders.first['email']
    assert_equal 'newsletter', orders.first['via']

    tickets_rpc = mcp_tool_call('get_event_tickets_tool', arguments: { id: @event.id.to_s }, headers: headers)
    tickets = JSON.parse(tool_text(tickets_rpc))

    assert_equal 200, last_response.status
    refute tickets_rpc.dig('result', 'isError')
    assert_equal 1, tickets.length
    assert_equal @ticket.id.to_s, tickets.first['id']
    assert_equal @attendee.name, tickets.first['name']
    assert_equal @attendee.email, tickets.first['email']
    assert_equal @event.ticket_types.first.name, tickets.first['ticket_type']
    assert_equal @order.id.to_s, tickets.first['order_id']
  end

  test 'non-admin cannot query event orders or tickets' do
    create_event_with_order_and_ticket
    stranger = FactoryBot.create(:account)
    headers = { 'Authorization' => "Bearer #{stranger.api_key}" }

    %w[get_event_orders_tool get_event_tickets_tool].each do |name|
      rpc = mcp_tool_call(name, arguments: { slug: @event.slug }, headers: headers)

      assert_equal 200, last_response.status
      assert rpc.dig('result', 'isError')
      assert_includes tool_text(rpc), 'You do not have access to this event'
    end
  end

  test 'get_event_orders_tool returns all completed orders' do
    create_event_with_order_and_ticket
    21.times do
      @event.orders.create!(
        account: @attendee,
        currency: @event.currency,
        value: 0,
        payment_completed: true,
        original_description: 'MCP unbounded order'
      )
    end
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    orders = JSON.parse(tool_text(mcp_tool_call('get_event_orders_tool', arguments: { slug: @event.slug }, headers: headers)))

    assert_equal 22, orders.length
  end

  test 'get_event_tickets_tool returns all completed tickets' do
    create_event_with_order_and_ticket
    @event.ticket_types.first.set(quantity: 100)
    21.times do
      @event.tickets.create!(
        account: @attendee,
        order: @order,
        ticket_type: @event.ticket_types.first,
        payment_completed: true
      )
    end
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    tickets = JSON.parse(tool_text(mcp_tool_call('get_event_tickets_tool', arguments: { slug: @event.slug }, headers: headers)))

    assert_equal 22, tickets.length
  end

  test 'organisation admin can list hosted and cohosted events' do
    create_event_with_order_and_ticket
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    rpc = mcp_tool_call('get_organisation_events_tool', arguments: { slug: @organisation.slug }, headers: headers)
    events = JSON.parse(tool_text(rpc))

    assert_equal 200, last_response.status
    refute rpc.dig('result', 'isError')
    assert_equal 1, events.length
    assert_equal @event.id.to_s, events.first['id']
    assert_equal @event.slug, events.first['slug']
    assert_includes events.first['name'], @event.name
  end

  test 'organisation admin can list recent followers' do
    create_event_with_order_and_ticket
    follower = FactoryBot.create(:account, name: 'New Follower')
    organisationship = @organisation.organisationships.create!(account: follower)
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    rpc = mcp_tool_call('get_organisation_followers_tool', arguments: { id: @organisation.id.to_s }, headers: headers)
    followers = JSON.parse(tool_text(rpc))

    assert_equal 200, last_response.status
    refute rpc.dig('result', 'isError')
    match = followers.find { |row| row['id'] == organisationship.id.to_s }
    assert match
    assert_equal follower.name, match['name']
    assert_equal follower.email, match['email']
  end

  test 'non-admin cannot query organisation events or followers' do
    create_event_with_order_and_ticket
    stranger = FactoryBot.create(:account)
    headers = { 'Authorization' => "Bearer #{stranger.api_key}" }

    %w[get_organisation_events_tool get_organisation_followers_tool].each do |name|
      rpc = mcp_tool_call(name, arguments: { slug: @organisation.slug }, headers: headers)

      assert_equal 200, last_response.status
      assert rpc.dig('result', 'isError')
      assert_includes tool_text(rpc), 'You do not have access to this organisation'
    end
  end

  test 'event order and ticket tools hide emails from event admins who cannot view them' do
    facilitator = FactoryBot.create(:account)
    attendee = FactoryBot.create(:account, name: 'Hidden Email')
    create_event(prices: [0], show_emails: false)
    @event.event_facilitations.create!(account: facilitator)
    order = @event.orders.create!(account: attendee, currency: @event.currency, value: 0, payment_completed: true, original_description: 'MCP privacy test')
    @event.tickets.create!(account: attendee, order: order, ticket_type: @event.ticket_types.first, payment_completed: true)
    headers = { 'Authorization' => "Bearer #{facilitator.api_key}" }

    orders = JSON.parse(tool_text(mcp_tool_call('get_event_orders_tool', arguments: { slug: @event.slug }, headers: headers)))
    tickets = JSON.parse(tool_text(mcp_tool_call('get_event_tickets_tool', arguments: { slug: @event.slug }, headers: headers)))

    assert_equal '', orders.first['email']
    assert_equal attendee.name, orders.first['name']
    assert_equal '', tickets.first['email']
    assert_equal attendee.name, tickets.first['name']
  end

  test 'get_event_tool includes public ticket types' do
    create_event(prices: [10, '5-20', ''])
    @event.ticket_types.create!(name: 'Secret', price: 1, quantity: 5, hidden: true)

    rpc = mcp_tool_call('get_event_tool', arguments: { slug: @event.slug })
    payload = JSON.parse(tool_text(rpc))

    refute rpc.dig('result', 'isError')
    assert_equal 'GBP', payload['currency']
    ticket_types = payload['ticket_types'].index_by { |ticket_type| ticket_type['pricing'] }
    assert_equal %w[fixed pay_what_you_want range], ticket_types.keys.sort
    assert_equal 10.0, ticket_types['fixed']['price']
    assert_equal 100, ticket_types['fixed']['available']
    assert_equal [5.0, 20.0], ticket_types['range'].values_at('price_min', 'price_max')
    assert(payload['ticket_types'].none? { |ticket_type| ticket_type['name'] == 'Secret' })
  end

  test 'get_event_checkout_requirements_tool describes the checkout form' do
    create_event(prices: [0], ask_hear_about: true, opt_in_organisation: true,
                 questions: "# About you\nDietary requirements\nT-shirt size <S, M, L>*\n[I agree to the code of conduct]*")
    @organisation.update_attributes!(collect_phone: true)

    rpc = mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })
    payload = JSON.parse(tool_text(rpc))

    refute rpc.dig('result', 'isError')
    assert payload['purchasable']
    assert_empty payload['restrictions']
    assert_equal @event.ticket_types.first.id.to_s, payload['ticket_types'].first['id']
    assert_equal %w[name email phone hear_about], payload['buyer_fields'].pluck('name')
    assert_equal %w[heading text select checkbox], payload['questions'].pluck('type')
    assert_equal [0, 1, 2, 3], payload['questions'].pluck('index')
    assert_equal %w[S M L], payload['questions'][2]['options']
    assert payload['questions'][3]['required']
    refute payload['questions'][1]['required']
    assert_equal ['opt_in_organisation'], payload['opt_ins'].pluck('name')
    assert_includes payload['payment_methods'].pluck('name'), 'rsvp'
  end

  test 'get_event_checkout_requirements_tool reports restrictions and hides secret events' do
    create_event(prices: [10], monthly_donors_only: true)
    restricted = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))

    refute restricted['purchasable']
    assert_equal ['monthly_donors_only'], restricted['restrictions']

    create_event(prices: [10], secret: true, as: :secret_event)
    rpc = mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @secret_event.slug })

    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), 'Event not found'
  end

  def buyer_headers
    @buyer ||= FactoryBot.create(:account)
    { 'Authorization' => "Bearer #{@buyer.api_key}" }
  end

  def create_checkout(arguments)
    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug }.merge(arguments), headers: buyer_headers)
    [rpc, (JSON.parse(tool_text(rpc)) unless rpc.dig('result', 'isError'))]
  end

  def with_stubbed_stripe_session(&)
    session = OpenStruct.new(id: 'cs_test', payment_intent: 'pi_test', url: 'https://checkout.stripe.com/test')
    Stripe::Checkout::Session.stub(:create, session, &)
  end

  test 'create_checkout_tool requires authentication' do
    create_event(prices: [0])
    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug, quantities: { @event.ticket_types.first.id.to_s => 1 } })

    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), 'Authentication required'
  end

  test 'create_checkout_tool books a free event for the authenticated account' do
    create_event(prices: [0], questions: "Dietary requirements\nT-shirt size <S, M, L>*")
    ticket_type = @event.ticket_types.first

    _rpc, order = create_checkout(quantities: { ticket_type.id.to_s => 2 }, answers: { '1' => 'M' })

    assert_equal 'complete', order['status']
    assert_nil order['checkout_url']
    assert_equal 2, order['tickets'].length
    record = Order.find(order['order_id'])
    assert_equal @buyer, record.account
    assert_equal 'mcp', record.via
    assert_equal [['Dietary requirements', nil], ['T-shirt size <S, M, L>*', 'M']], record.answers
    assert_equal 2, @event.tickets.complete.and(account_id: @buyer.id).count
  end

  test 'create_checkout_tool returns a payment link for a paid event' do
    create_event(prices: [10])
    ticket_type = @event.ticket_types.first

    order = nil
    with_stubbed_stripe_session do
      _rpc, order = create_checkout(quantities: { ticket_type.id.to_s => 1 })
    end

    assert_equal 'awaiting_payment', order['status']
    assert_equal 'https://checkout.stripe.com/test', order['checkout_url']
    assert_equal 10.0, order['total']
    assert order['pay_by']

    status_rpc = mcp_tool_call('get_order_status_tool', arguments: { order_id: order['order_id'] }, headers: buyer_headers)
    assert_equal 'awaiting_payment', JSON.parse(tool_text(status_rpc))['status']

    Order.find(order['order_id']).destroy
    status_rpc = mcp_tool_call('get_order_status_tool', arguments: { order_id: order['order_id'] }, headers: buyer_headers)
    assert_equal 'expired', JSON.parse(tool_text(status_rpc))['status']
  end

  test 'create_checkout_tool returns the first order when retried with the same idempotency key' do
    create_event(prices: [10])
    ticket_type = @event.ticket_types.first

    first = second = nil
    with_stubbed_stripe_session do
      _rpc, first = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')
      _rpc, second = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')
    end

    assert_equal first['order_id'], second['order_id']
    assert_equal 1, @event.orders.count
  end

  test 'create_checkout_tool checks questions, terms, duplicates and the organisation setting' do
    create_event(prices: [0], questions: 'T-shirt size <S, M, L>*', terms_and_conditions: 'Be kind', terms_and_conditions_check_box: true)
    quantities = { @event.ticket_types.first.id.to_s => 1 }

    rpc, = create_checkout(quantities: quantities, accept_terms: true)
    assert_includes tool_text(rpc), 'Answer the required questions: T-shirt size'

    rpc, = create_checkout(quantities: quantities, answers: { '1' => 'M' }, accept_terms: true)
    assert_includes tool_text(rpc), 'Unknown question indexes: 1'

    rpc, = create_checkout(quantities: quantities, answers: { '0' => 'M' })
    assert_includes tool_text(rpc), 'accept the terms and conditions'

    _rpc, order = create_checkout(quantities: quantities, answers: { '0' => 'M' }, accept_terms: true)
    assert_equal 'complete', order['status']

    rpc, = create_checkout(quantities: quantities, answers: { '0' => 'M' }, accept_terms: true)
    assert_includes tool_text(rpc), 'has already been booked'

    _rpc, order = create_checkout(quantities: quantities, answers: { '0' => 'M' }, accept_terms: true, confirm_duplicate: true)
    assert_equal 'complete', order['status']

    @organisation.update_attributes!(no_agent_bookings: true)
    rpc, = create_checkout(quantities: quantities, answers: { '0' => 'M' }, accept_terms: true, confirm_duplicate: true)
    assert_includes tool_text(rpc), 'does not take bookings from AI agents'
    assert_equal 2, @event.orders.count
  end

  test 'create_checkout_tool does not sell hidden ticket types' do
    create_event(prices: [0])
    hidden = @event.ticket_types.create!(name: 'Secret', price: 0, quantity: 5, hidden: true)

    rpc, = create_checkout(quantities: { hidden.id.to_s => 1 })

    assert_includes tool_text(rpc), 'Ticket type not found'
    assert_equal 0, @event.orders.count
  end

  test 'get_order_status_tool is only available to the buyer and event admins' do
    create_event(prices: [0])
    _rpc, order = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 })
    stranger = FactoryBot.create(:account)

    rpc = mcp_tool_call('get_order_status_tool', arguments: { order_id: order['order_id'] }, headers: { 'Authorization' => "Bearer #{stranger.api_key}" })
    assert_includes tool_text(rpc), 'Order not found'

    rpc = mcp_tool_call('get_order_status_tool', arguments: { order_id: order['order_id'] }, headers: { 'Authorization' => "Bearer #{@account.api_key}" })
    assert_equal 'complete', JSON.parse(tool_text(rpc))['status']
  end
end
