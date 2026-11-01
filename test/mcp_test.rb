require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

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
    %w[get_event_orders_tool get_event_tickets_tool get_organisation_events_tool get_organisation_followers_tool get_organisation_orders_tool].each do |name|
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

  test 'organisation admin can list orders across all events, including cohosted ones' do
    create_event_with_order_and_ticket
    create_event(prices: [0], as: :event2)
    later_order = @event2.orders.create!(account: @attendee, currency: @event2.currency, value: 0, payment_completed: true, original_description: 'MCP second event order', opt_in_organisation: true)
    @event2.orders.create!(account: @attendee, currency: @event2.currency, value: 0, payment_completed: false, original_description: 'MCP incomplete order')
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    cohosted_event = FactoryBot.create(:event, organisation: other_organisation, prices: [0])
    cohosted_event.cohostships.create!(organisation: @organisation)
    cohosted_order = cohosted_event.orders.create!(account: @attendee, currency: cohosted_event.currency, value: 0, payment_completed: true, original_description: 'MCP cohosted order')
    other_order = FactoryBot.create(:event, organisation: other_organisation, prices: [0]).orders.create!(account: @attendee, currency: 'GBP', value: 0, payment_completed: true, original_description: 'MCP other organisation order')
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    rpc = mcp_tool_call('get_organisation_orders_tool', arguments: { slug: @organisation.slug }, headers: headers)
    orders = JSON.parse(tool_text(rpc))

    assert_equal 200, last_response.status
    refute rpc.dig('result', 'isError')
    order_ids = orders.map { |row| row['id'] }
    assert_equal [cohosted_order.id.to_s, later_order.id.to_s, @order.id.to_s], order_ids
    refute_includes order_ids, other_order.id.to_s
    second = orders.find { |row| row['id'] == later_order.id.to_s }
    assert_equal @event2.id.to_s, second['event_id']
    assert_equal @event2.name, second['event_name']
    assert_equal "#{ENV['BASE_URI']}/e/#{@event2.slug}", second['event_url']
    assert_equal @attendee.email, second['email']
    assert second['opt_in_organisation']
  end

  test 'organisation orders put an order that completes later above newer orders' do
    create_event_with_order_and_ticket
    pending_order = @event.orders.create!(account: @attendee, currency: @event.currency, value: 10, payment_completed: false, original_description: 'MCP late payment')
    newer_order = @event.orders.create!(account: @attendee, currency: @event.currency, value: 0, payment_completed: true, original_description: 'MCP newer order')
    assert_nil pending_order.completed_at
    pending_order.payment_completed!
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    orders = JSON.parse(tool_text(mcp_tool_call('get_organisation_orders_tool', arguments: { slug: @organisation.slug }, headers: headers)))

    assert_equal([pending_order.id.to_s, newer_order.id.to_s, @order.id.to_s], orders.map { |row| row['id'] })
    assert orders.first['completed_at']
  end

  test 'organisation orders list orders without completed_at last, newest first' do
    create_event_with_order_and_ticket
    yesterday_order = @event.orders.create!(account: @attendee, currency: @event.currency, value: 0, payment_completed: true, original_description: 'MCP older order')
    [@order, yesterday_order].each { |order| order.unset(:completed_at) }
    @order.set(created_at: 2.days.ago)
    yesterday_order.set(created_at: 1.day.ago)
    newer_order = @event.orders.create!(account: @attendee, currency: @event.currency, value: 0, payment_completed: true, original_description: 'MCP newer order')
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    orders = JSON.parse(tool_text(mcp_tool_call('get_organisation_orders_tool', arguments: { slug: @organisation.slug }, headers: headers)))

    assert_equal([newer_order.id.to_s, yesterday_order.id.to_s, @order.id.to_s], orders.map { |row| row['id'] })
    assert_nil orders.last['completed_at']
  end

  test 'non-admin cannot query organisation events or followers' do
    create_event_with_order_and_ticket
    stranger = FactoryBot.create(:account)
    headers = { 'Authorization' => "Bearer #{stranger.api_key}" }

    %w[get_organisation_events_tool get_organisation_followers_tool get_organisation_orders_tool].each do |name|
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
    rsvp = payload['payment_methods'].find { |payment_method| payment_method['name'] == 'rsvp' }
    assert rsvp['free_only']
    assert rsvp['agent_checkout']
  end

  test 'get_event_checkout_requirements_tool reports restrictions and hides secret events' do
    create_event(prices: [10], monthly_donors_only: true)
    restricted = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))

    refute restricted['purchasable']
    assert_equal ['monthly_donors_only'], restricted['restrictions']

    create_event(as: :event_without_tickets)
    without_tickets = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event_without_tickets.slug })))

    refute without_tickets['purchasable']
    assert_equal ['no_tickets'], without_tickets['restrictions']

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
    session = api_object(id: 'cs_test', payment_intent: 'pi_test', url: 'https://checkout.stripe.com/test')
    Stripe::Checkout::Session.stub(:create, session, &)
  end

  test 'create_checkout_tool books for the buyer given without an API key' do
    create_event(prices: [0])
    quantities = { @event.ticket_types.first.id.to_s => 1 }

    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug, quantities: quantities })
    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), 'Provide buyer'

    buyer = { name: 'Agent Buyer', email: 'Agent.Buyer@example.com' }
    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug, quantities: quantities, buyer: buyer, idempotency_key: 'anon-1' })
    order = JSON.parse(tool_text(rpc))
    assert_equal 'complete', order['status']
    account = Order.find(order['order_id']).account
    assert_equal 'agent.buyer@example.com', account.email
    assert_equal 'Agent Buyer', account.name

    # A retry finds the order through the buyer's email, but without an API key doesn't get its details
    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug, quantities: quantities, buyer: buyer, idempotency_key: 'anon-1' })
    retry_order = JSON.parse(tool_text(rpc))
    assert_equal order['order_id'], retry_order['order_id']
    assert_equal 'complete', retry_order['status']
    assert_nil retry_order['tickets']
    assert_equal 1, @event.tickets.count
  end

  test 'create_checkout_tool keeps the details of a booking made with an API key from a retry without one' do
    create_event(prices: [10])
    with_stubbed_stripe_session do
      _rpc, order = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 }, idempotency_key: 'retry-1')
      assert_equal 'https://checkout.stripe.com/test', order['checkout_url']

      # Rack::Test keeps headers between requests
      header 'Authorization', nil
      rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug, quantities: { @event.ticket_types.first.id.to_s => 1 },
                                                               buyer: { name: 'Someone', email: @buyer.email }, idempotency_key: 'retry-1' })
      retry_order = JSON.parse(tool_text(rpc))
      assert_equal order['order_id'], retry_order['order_id']
      assert_nil retry_order['checkout_url']
    end
  end

  test 'create_checkout_tool takes the opt-ins and hear_about the event asks for' do
    create_event(prices: [0], ask_hear_about: true, opt_in_organisation: true)
    quantities = { @event.ticket_types.first.id.to_s => 1 }

    rpc, = create_checkout(quantities: quantities, opt_ins: ['opt_in_facilitator'])
    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), "doesn't offer these opt-ins: opt_in_facilitator"

    # With an API key, buyer is only read for hear_about
    _rpc, order = create_checkout(quantities: quantities, opt_ins: ['opt_in_organisation'], buyer: { name: 'Ignored', hear_about: 'A friend' })
    record = Order.find(order['order_id'])
    assert_equal @buyer, record.account
    assert record.opt_in_organisation
    assert_equal 'A friend', record.hear_about
    assert @organisation.organisationships.find_by(account: @buyer)
  end

  test 'create_checkout_tool books an existing account without changing it, when given its email without an API key' do
    create_event(prices: [0])
    existing = FactoryBot.create(:account, name: 'Original Name')

    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug, quantities: { @event.ticket_types.first.id.to_s => 1 },
                                                             buyer: { name: 'Someone Else', email: existing.email } })
    order = JSON.parse(tool_text(rpc))
    assert_equal existing, Order.find(order['order_id']).account
    assert_equal 'Original Name', existing.reload.name
  end

  test 'create_checkout_tool books a free event for the authenticated account' do
    create_event(prices: [0], questions: "Dietary requirements\nT-shirt size <S, M, L>*\n[Photos are fine]\n[Add me to the list]")
    ticket_type = @event.ticket_types.first

    # phone isn't an argument the tool takes, and is ignored
    _rpc, order = create_checkout(quantities: { ticket_type.id.to_s => 2 }, answers: { '1' => 'M', '2' => true, '3' => false }, phone: '+447700900000')

    assert_equal 'complete', order['status']
    assert_nil order['checkout_url']
    assert_equal 2, order['tickets'].length
    record = Order.find(order['order_id'])
    assert_equal @buyer, record.account
    assert_equal 'mcp', record.via
    # As the checkout form stores them: a ticked checkbox as '1', and an unticked one not at all
    assert_equal [['Dietary requirements', nil], ['T-shirt size <S, M, L>*', 'M'], ['[Photos are fine]', '1']], record.answers
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
    assert_equal 'https://checkout.stripe.com/test', Order.find(order['order_id']).checkout_url
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

    Order.find(first['order_id']).destroy
    _rpc, third = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')

    assert_equal first['order_id'], third['order_id']
    assert_equal 'expired', third['status']
    assert_includes third['message'], 'new idempotency_key'
    assert_nil third['total']
    assert_equal 1, Order.unscoped.and(event_id: @event.id).count
  end

  test 'create_checkout_tool says a retry is still processing while the first call sets up payment' do
    create_event(prices: [10])
    ticket_type = @event.ticket_types.first

    first = nil
    with_stubbed_stripe_session do
      _rpc, first = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')
    end
    # As the order is while the first call waits for the payment provider
    Order.find(first['order_id']).unset(:checkout_url)

    _rpc, second = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')

    assert_equal first['order_id'], second['order_id']
    assert_equal 'processing', second['status']
    assert_includes second['message'], 'in a few seconds'
    assert_nil second['checkout_url']
  end

  test 'create_checkout_tool books again when retried after the first attempt failed' do
    create_event(prices: [10])
    ticket_type = @event.ticket_types.first

    Stripe::Checkout::Session.stub(:create, ->(*) { raise 'Stripe is down' }) do
      rpc, = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')
      assert_includes tool_text(rpc), 'Booking failed. Please try again.'
      refute_includes tool_text(rpc), 'Stripe is down'
    end

    order = nil
    with_stubbed_stripe_session do
      _rpc, order = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')
    end

    assert_equal 'awaiting_payment', order['status']
    assert_equal 'https://checkout.stripe.com/test', order['checkout_url']
    assert_equal 1, @event.orders.count
    assert_equal 1, Order.unscoped.and(event_id: @event.id, idempotency_key: 'retry-1').count
  end

  test 'create_checkout_tool returns the first order when a retry of a free booking arrives at the same time' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    _rpc, first = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')

    # The retry's lookup runs before the first order exists, and it then finds the first order's ticket
    idempotent_order = Dandelion::MCP.method(:idempotent_order)
    lookups = 0
    second = nil
    Dandelion::MCP.stub(:idempotent_order, ->(*args) { (lookups += 1) == 1 ? nil : idempotent_order.call(*args) }) do
      _rpc, second = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')
    end

    assert_equal first['order_id'], second['order_id']
    assert_equal 'complete', second['status']
    assert_equal 1, @event.orders.count
  end

  test 'create_checkout_tool books paid tickets that credit covers, with no payment method agents can use' do
    create_event(prices: [10], suggested_donation: 0)
    buyer_headers
    @organisation.organisationships.find_or_create_by(account: @buyer).creditings.create!(account: @account, amount: 10, currency: @event.currency)

    order = nil
    Dandelion::MCP.stub(:event_agent_payment_methods, []) do
      _rpc, order = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 })
    end

    assert_equal 'complete', order['status']
    assert_equal 10, Order.find(order['order_id']).credit_applied
  end

  test 'create_checkout_tool says to try again when the order it clashed with has already failed' do
    create_event(prices: [10])
    ticket_type = @event.ticket_types.first
    index = 'event_id_1_account_id_1_idempotency_key_1_unique'
    Order.collection.indexes.create_one({ event_id: 1, account_id: 1, idempotency_key: 1 },
                                        name: index, unique: true, partial_filter_expression: { idempotency_key: { '$type' => 'string' } })

    rpc = nil
    with_stubbed_stripe_session do
      create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')
      # Neither lookup finds the first order, as if it failed and freed its key just after the clash
      Dandelion::MCP.stub(:idempotent_order, nil) do
        rpc, = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')
      end
    end

    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), 'Booking failed. Please try again.'
  ensure
    Order.collection.indexes.drop_one(index)
  end

  test 'create_checkout_tool returns the first order when a retry arrives at the same time' do
    create_event(prices: [10])
    ticket_type = @event.ticket_types.first
    index = 'event_id_1_account_id_1_idempotency_key_1_unique'
    Order.collection.indexes.create_one({ event_id: 1, account_id: 1, idempotency_key: 1 },
                                        name: index, unique: true, partial_filter_expression: { idempotency_key: { '$type' => 'string' } })

    first = second = nil
    with_stubbed_stripe_session do
      _rpc, first = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')

      # The retry's lookup runs before the first order exists
      idempotent_order = Dandelion::MCP.method(:idempotent_order)
      lookups = 0
      Dandelion::MCP.stub(:idempotent_order, ->(*args) { (lookups += 1) == 1 ? nil : idempotent_order.call(*args) }) do
        _rpc, second = create_checkout(quantities: { ticket_type.id.to_s => 1 }, idempotency_key: 'retry-1')
      end
    end

    assert_equal first['order_id'], second['order_id']
    assert_equal 1, Order.unscoped.and(event_id: @event.id).count
  ensure
    Order.collection.indexes.drop_one(index)
  end

  test 'create_checkout_tool checks questions, terms and duplicates' do
    create_event(prices: [0], questions: 'T-shirt size <S, M, L>*', terms_and_conditions: 'Be kind', terms_and_conditions_check_box: true)
    quantities = { @event.ticket_types.first.id.to_s => 1 }

    rpc, = create_checkout(quantities: quantities, accept_terms: true)
    assert_includes tool_text(rpc), 'Answer the required questions: T-shirt size'

    rpc, = create_checkout(quantities: quantities, answers: { '1' => 'M' }, accept_terms: true)
    assert_includes tool_text(rpc), 'Unknown question indexes: 1'

    rpc, = create_checkout(quantities: quantities, answers: { '0' => 'XL' }, accept_terms: true)
    assert_includes tool_text(rpc), 'Choose one of the options: T-shirt size (S, M, L)'

    rpc, = create_checkout(quantities: quantities, answers: { '0' => 'M' })
    assert_includes tool_text(rpc), 'accept the terms and conditions'

    _rpc, order = create_checkout(quantities: quantities, answers: { '0' => 'M' }, accept_terms: true)
    assert_equal 'complete', order['status']

    rpc, = create_checkout(quantities: quantities, answers: { '0' => 'M' }, accept_terms: true)
    assert_includes tool_text(rpc), 'already has a ticket to this event'
    assert_equal 1, @event.orders.count
  end

  test 'create_checkout_tool refuses what agents cannot book' do
    create_event(prices: [10, '10-100', nil])
    fixed = @event.ticket_types.detect(&:price)
    range = @event.ticket_types.detect(&:range)
    pay_what_you_want = @event.ticket_types.detect { |ticket_type| !ticket_type.price && !ticket_type.range }

    rpc, = create_checkout(quantities: { fixed.id.to_s => 0 })
    assert_includes tool_text(rpc), 'Choose at least one ticket.'

    rpc, = create_checkout(quantities: { range.id.to_s => 1 })
    assert_includes tool_text(rpc), 'only book fixed-price tickets'

    rpc, = create_checkout(quantities: { pay_what_you_want.id.to_s => 1 })
    assert_includes tool_text(rpc), 'only book fixed-price tickets'

    Dandelion::MCP.stub(:event_agent_payment_methods, []) do
      rpc, = create_checkout(quantities: { fixed.id.to_s => 1 })
    end
    assert_includes tool_text(rpc), 'no payment methods agents can use'

    fixed.update_attributes!(sales_end: 1.day.ago)
    rpc, = create_checkout(quantities: { fixed.id.to_s => 1 })
    assert_includes tool_text(rpc), 'Sales of that ticket type have ended'

    # Event.live leaves out locked events
    @event.set(locked: true)
    rpc, = create_checkout(quantities: { fixed.id.to_s => 1 })
    assert_includes tool_text(rpc), 'Event not found'
    assert_equal 0, @event.orders.count
  end

  test 'create_checkout_tool sends the buyer to the event page when the event needs a donation' do
    create_event(prices: [0], suggested_donation: 10, minimum_donation: 5)
    assert_equal 5, @event.minimum_donation
    requirements = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))
    assert_includes requirements['restrictions'], 'donation_required'

    rpc, = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 })

    assert_includes tool_text(rpc), 'A donation of at least £5 is required.'
    assert_includes tool_text(rpc), 'send the buyer to the event page'
    assert_equal 0, @event.orders.count
  end

  test 'create_checkout_tool says when a ticket type is only for monthly donors' do
    create_event(prices: [0])
    @event.ticket_types.first.set(minimum_monthly_donation: 10)

    rpc, = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 })

    assert_includes tool_text(rpc), 'only for monthly donors'
    assert_equal 0, @event.orders.count
  end

  test 'create_checkout_tool keeps to who may book the event' do
    create_event(prices: [0], monthly_donors_only: true)

    rpc, = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 })

    assert_includes tool_text(rpc), 'Only monthly donors to this organisation can book this event'
    assert_equal 0, @event.orders.count
  end

  test 'create_checkout_tool does not sell hidden ticket types' do
    create_event(prices: [0])
    hidden = @event.ticket_types.create!(name: 'Secret', price: 0, quantity: 5, hidden: true)

    rpc, = create_checkout(quantities: { hidden.id.to_s => 1 })

    assert_includes tool_text(rpc), 'Ticket type not found'
    assert_equal 0, @event.orders.count
  end
end
