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
    covers 'integrations/public-tools-work-without-key@1474aa'
    rpc = mcp_tool_call('get_trending_events_tool', arguments: { limit: 1 })

    assert_equal 200, last_response.status
    assert rpc.dig('result', 'content')
    refute rpc.dig('result', 'isError')
  end

  test 'get_me_tool requires authentication' do
    covers 'integrations/authenticated-tools-require-key@f25321'
    rpc = mcp_tool_call('get_me_tool')

    assert_equal 200, last_response.status
    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), 'Authentication required'
  end

  test 'get_me_tool returns the authenticated account' do
    covers 'integrations/authenticated-tools-require-key@f25321', 'integrations/account-returns-authenticated-account@f5b358'
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
    covers 'integrations/invalid-key-rejected@a21fde'
    mcp_tool_call('get_me_tool', headers: { 'Authorization' => 'Bearer not-a-real-key' })

    assert_equal 401, last_response.status
    assert_equal 'Bearer', last_response['WWW-Authenticate']
    assert_equal 'invalid_token', JSON.parse(last_response.body)['error']
  end

  test 'event order and ticket tools require authentication' do
    covers 'integrations/authenticated-tools-require-key@f25321'
    %w[get_event_orders_tool get_event_tickets_tool get_organisation_events_tool get_organisation_followers_tool get_organisation_orders_tool].each do |name|
      rpc = mcp_tool_call(name, arguments: { slug: 'example' })

      assert_equal 200, last_response.status
      assert rpc.dig('result', 'isError')
      assert_includes tool_text(rpc), 'Authentication required'
    end
  end

  test 'event admin can query orders and tickets' do
    covers 'integrations/event-orders-returns-completed-orders@2599ad', 'integrations/event-tickets-returns-completed-tickets@2c4319'
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
    covers 'integrations/event-orders-returns-completed-orders@2599ad', 'integrations/event-tickets-returns-completed-tickets@2c4319'
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
    covers 'integrations/event-orders-returns-completed-orders@2599ad'
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
    covers 'integrations/event-tickets-returns-completed-tickets@2c4319'
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
    covers 'integrations/organisation-events-returns-events@1b8177'
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
    covers 'integrations/organisation-followers-last-24-hours@8e8cf5'
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
    covers 'integrations/organisation-orders-most-recently-completed@db1be3', 'integrations/opt-in-organisation-field@c68ae5'
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
    covers 'integrations/organisation-orders-most-recently-completed@db1be3'
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
    covers 'integrations/organisation-orders-most-recently-completed@db1be3', 'integrations/completed-at-null-for-older-orders@63c67d'
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
    covers 'integrations/organisation-events-returns-events@1b8177', 'integrations/organisation-orders-most-recently-completed@db1be3'
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
    covers 'events/facilitator-no-organisation-access@ec2446', 'organisations/attendee-emails-admins-and-managers-only@10b712', 'integrations/order-email-may-be-empty@d03f03', 'integrations/ticket-emails-may-be-empty@54ad94', 'integrations/emails-only-when-allowed@a6c1bb'
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
    covers 'integrations/requirements-public-ticket-types@b1c443', 'integrations/look-up-by-slug-or-id@d69717', 'integrations/events-include-currency-ticket-types@18bab5'
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
    covers 'integrations/checkout-requirements-says-what-booking-involves@610554', 'integrations/requirements-bookable-and-why-not@11def2', 'integrations/requirements-buyer-details-questions-opt-ins@3cbcec', 'integrations/requirements-payment-methods@48eafc'
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

  test 'get_event_checkout_requirements_tool reports restrictions' do
    covers 'integrations/requirements-bookable-and-why-not@11def2'
    create_event(prices: [10], monthly_donors_only: true)
    restricted = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))

    refute restricted['purchasable']
    assert_equal ['monthly_donors_only'], restricted['restrictions']

    create_event(as: :event_without_tickets)
    without_tickets = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event_without_tickets.slug })))

    refute without_tickets['purchasable']
    assert_equal ['no_tickets'], without_tickets['restrictions']
  end

  test 'secret events are found by their slug or a link to them, never by id, and can be booked' do
    covers 'integrations/tools-take-event-link-as-slug@7a5e0d', 'integrations/secret-event-found-by-slug-or-link@d9e645'
    create_event(prices: [0], secret: true)
    link = "#{ENV['BASE_URI']}/e/#{@event.slug}?utm_source=newsletter"

    rpc = mcp_tool_call('get_event_checkout_requirements_tool', arguments: { id: @event.id.to_s })
    assert_includes tool_text(rpc), 'Event not found'
    rpc = mcp_tool_call('get_event_tool', arguments: { id: @event.id.to_s })
    assert_includes tool_text(rpc), 'Event not found'

    assert JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))['purchasable']
    assert_equal @event.name, JSON.parse(tool_text(mcp_tool_call('get_event_tool', arguments: { slug: @event.slug })))['name']

    _rpc, order = create_checkout(slug: link, quantities: { @event.ticket_types.first.id.to_s => 1 })
    assert_equal 'complete', order['status']
    assert_equal @event.slug, order['event']['slug']
  end

  def buyer_headers
    @buyer ||= FactoryBot.create(:account)
    { 'Authorization' => "Bearer #{@buyer.api_key}" }
  end

  def create_checkout(arguments)
    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug }.merge(arguments), headers: buyer_headers)
    [rpc, (JSON.parse(tool_text(rpc)) unless rpc.dig('result', 'isError'))]
  end

  test 'create_checkout_tool books for the buyer given without an API key' do
    covers 'integrations/checkout-books-for-buyer-without-api-key@f7be6d', 'integrations/idempotency-retry-without-key-id-and-status@664443'
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
    covers 'integrations/idempotency-retry-without-key-id-and-status@664443'
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
    covers 'integrations/checkout-opt-ins@ca9668', 'integrations/checkout-hear-about@3cc931'
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
    covers 'integrations/checkout-books-for-buyer-without-api-key@f7be6d'
    create_event(prices: [0])
    existing = FactoryBot.create(:account, name: 'Original Name')

    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug, quantities: { @event.ticket_types.first.id.to_s => 1 },
                                                             buyer: { name: 'Someone Else', email: existing.email } })
    order = JSON.parse(tool_text(rpc))
    assert_equal existing, Order.find(order['order_id']).account
    assert_equal 'Original Name', existing.reload.name
  end

  test 'create_checkout_tool books a free event for the authenticated account' do
    covers 'integrations/checkout-books-as-you-with-api-key@06e7e4', 'integrations/checkout-answers-by-index@c3d14e', 'integrations/free-bookings-confirmed@d14b75', 'integrations/orders-via-mcp@5bbb5f'
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
    covers 'integrations/checkout-payment-method@c5f11b', 'integrations/paid-bookings-checkout-url-pay-by@0961c7'
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
    covers 'integrations/idempotency-retry-returns-first-order@fb1f36'
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
    covers 'integrations/idempotency-retry-returns-first-order@fb1f36'
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
    covers 'integrations/idempotency-failed-retry-books-again@8344c5'
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
    covers 'integrations/idempotency-retry-returns-first-order@fb1f36'
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
    covers 'integrations/order-includes-discounts-credit-donation@873ca3'
    create_event(prices: [10], suggested_donation: 0)
    buyer_headers
    @organisation.organisationships.find_or_create_by(account: @buyer).creditings.create!(account: @account, amount: 10, currency: @event.currency)

    order = nil
    Dandelion::MCP.stub(:event_agent_payment_methods, []) do
      _rpc, order = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 })
    end

    assert_equal 'complete', order['status']
    assert_equal 10, Order.find(order['order_id']).credit_applied
    assert_equal 10, order['discounts']['credit']
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
    covers 'integrations/idempotency-retry-returns-first-order@fb1f36'
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
    covers 'integrations/checkout-answers-by-index@c3d14e', 'integrations/checkout-accept-terms@f6946b', 'integrations/checkout-confirm-duplicate@ecdd19'
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
    assert_includes tool_text(rpc), 'confirm_duplicate'
    assert_equal 1, @event.orders.count

    # As the checkout form books again once the buyer confirms
    _rpc, order = create_checkout(quantities: quantities, answers: { '0' => 'M' }, accept_terms: true, confirm_duplicate: true)
    assert_equal 'complete', order['status']
    assert_equal 2, @event.orders.count
  end

  test 'create_checkout_tool asks to confirm an email that looks mistyped, without an API key' do
    covers 'integrations/checkout-confirm-email@d67261'
    create_event(prices: [0])
    quantities = { @event.ticket_types.first.id.to_s => 1 }
    buyer = { name: 'Typo Buyer', email: 'typo@gmial.com' }

    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug, quantities: quantities, buyer: buyer })
    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), "The buyer's email address, typo@gmial.com, looks mistyped"
    assert_includes tool_text(rpc), 'confirm_email'
    assert_nil Account.find_by(email: 'typo@gmial.com')

    rpc = mcp_tool_call('create_checkout_tool', arguments: { slug: @event.slug, quantities: quantities, buyer: buyer, confirm_email: true })
    assert_equal 'complete', JSON.parse(tool_text(rpc))['status']

    # With an API key, the booking is for that account, with its own email
    @buyer = FactoryBot.create(:account, email: 'keyholder@hotmail.con')
    _rpc, order = create_checkout(quantities: quantities)
    assert_equal 'complete', order['status']
  end

  test 'create_checkout_tool refuses what agents cannot book' do
    covers 'integrations/checkout-prices-chosen-by-buyer@e549fb', 'integrations/error-links-to-event-page@87ed40'
    create_event(prices: [10, '10-100', nil])
    fixed = @event.ticket_types.detect(&:price)
    range = @event.ticket_types.detect(&:range)
    pay_what_you_want = @event.ticket_types.detect { |ticket_type| !ticket_type.price && !ticket_type.range }

    rpc, = create_checkout(quantities: { fixed.id.to_s => 0 })
    assert_includes tool_text(rpc), 'Choose at least one ticket.'

    # Agents don't choose a price for the buyer
    rpc, = create_checkout(quantities: { range.id.to_s => 1 })
    assert_includes tool_text(rpc), 'Ask the buyer how much they want to pay'
    assert_includes tool_text(rpc), "#{range.name} (from £10 to £100)"

    rpc, = create_checkout(quantities: { pay_what_you_want.id.to_s => 1 }, prices: { pay_what_you_want.id.to_s => -1 })
    assert_includes tool_text(rpc), "#{pay_what_you_want.name} (£0 or more)"

    # Sends the buyer to the event page with their choices filled in
    Dandelion::MCP.stub(:event_agent_payment_methods, []) do
      rpc, = create_checkout(quantities: { fixed.id.to_s => 1 })
    end
    assert_includes tool_text(rpc), 'no payment methods agents can use'
    assert_includes tool_text(rpc), "#{ENV['BASE_URI']}/e/#{@event.slug}?quantities%5B#{fixed.id}%5D=1#select-tickets"

    fixed.update_attributes!(sales_end: 1.day.ago)
    rpc, = create_checkout(quantities: { fixed.id.to_s => 1 })
    assert_includes tool_text(rpc), 'Sales of that ticket type have ended'

    # Event.live leaves out locked events
    @event.set(locked: true)
    rpc, = create_checkout(quantities: { fixed.id.to_s => 1 })
    assert_includes tool_text(rpc), 'Event not found'
    assert_equal 0, @event.orders.count
  end

  test 'create_checkout_tool adds the donation the buyer chose' do
    covers 'integrations/requirements-donation@d65d4f', 'integrations/checkout-donation-amount-minimum@dbdbe1', 'integrations/order-includes-discounts-credit-donation@873ca3'
    create_event(prices: [0], suggested_donation: 10, minimum_donation: 5)
    assert_equal 5, @event.minimum_donation
    requirements = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))
    assert_empty requirements['restrictions']
    assert_equal({ 'to' => 'organisation', 'name' => @organisation.name, 'suggested' => 10.0, 'minimum' => 5.0, 'required' => true }, requirements['donation'])
    quantities = { @event.ticket_types.first.id.to_s => 1 }

    rpc, = create_checkout(quantities: quantities)
    assert_includes tool_text(rpc), 'A donation of at least £5 is required.'
    assert_includes tool_text(rpc), 'pass it as donation_amount'

    rpc, = create_checkout(quantities: quantities, donation_amount: 4)
    assert_includes tool_text(rpc), 'A donation of at least £5 is required.'
    assert_equal 0, @event.orders.count

    order = nil
    with_stubbed_stripe_session do
      _rpc, order = create_checkout(quantities: quantities, donation_amount: 7)
    end
    assert_equal 'awaiting_payment', order['status']
    assert_equal 7.0, order['donation']
    assert_equal 7.0, order['total']
  end

  test 'create_checkout_tool takes a donation to Dandelion of at least the smallest unit' do
    covers 'integrations/requirements-donation@d65d4f', 'integrations/donation-to-dandelion-minimum-smallest-unit@71d952'
    create_event(prices: [10])
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    assert @event.reload.donations_to_dandelion?
    requirements = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))
    assert_equal({ 'to' => 'dandelion', 'name' => 'Dandelion', 'suggested' => nil, 'minimum' => 1.0, 'required' => false, 'added_by_default' => true },
                 requirements['donation'])
    quantities = { @event.ticket_types.first.id.to_s => 1 }

    rpc, = create_checkout(quantities: quantities, donation_amount: 0.1)
    assert_includes tool_text(rpc), 'A donation to Dandelion must be at least £1, or nothing.'
    assert_includes tool_text(rpc), 'pass a donation_amount of 0 to give nothing'
    assert_equal 0, @event.orders.count

    order = nil
    with_stubbed_stripe_session do
      _rpc, order = create_checkout(quantities: quantities, donation_amount: 1)
    end
    assert_equal 'awaiting_payment', order['status']
    assert_equal 11.0, order['total']
  end

  test 'create_checkout_tool adds the smallest donation to Dandelion unless given one' do
    covers 'integrations/donation-to-dandelion-minimum-smallest-unit@71d952', 'integrations/checkout-dandelion-donation-added-by-default@06a504'
    create_event(prices: [10, 100, 300])
    @organisation.set(stripe_pk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json, paid_up: false)
    ticket_types = @event.reload.ticket_types.sort_by(&:price)

    book = lambda do |ticket_type, **arguments|
      session = api_object(id: "cs_#{ticket_type.id}_#{arguments.key?(:donation_amount)}", payment_intent: "pi_#{ticket_type.id}_#{arguments.key?(:donation_amount)}",
                           url: 'https://checkout.stripe.com/test')
      Stripe::Checkout::Session.stub(:create, session) { create_checkout(quantities: { ticket_type.id.to_s => 1 }, **arguments).last }
    end

    # £1, whatever the tickets cost, not the checkout form's percentage
    assert_equal([[1.0, 11.0], [1.0, 101.0], [1.0, 301.0]], ticket_types.map { |ticket_type| book.(ticket_type).values_at('donation', 'total') })

    order = book.(ticket_types.first, donation_amount: 0)
    assert_nil order['donation']
    assert_equal 10.0, order['total']
  end

  test 'create_checkout_tool refuses a donation the event does not take' do
    covers 'integrations/checkout-donation-amount-minimum@dbdbe1'
    create_event(prices: [0])

    rpc, = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 }, donation_amount: 5)

    assert_includes tool_text(rpc), "doesn't take donations"
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
    covers 'integrations/error-links-to-event-page@87ed40'
    create_event(prices: [0], monthly_donors_only: true)

    rpc, = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 })

    assert_includes tool_text(rpc), 'Only monthly donors to this organisation can book this event'
    # Someone who can book it can do so on the event page, with their choices filled in
    assert_includes tool_text(rpc), "signed in at #{ENV['BASE_URI']}/e/#{@event.slug}?quantities%5B#{@event.ticket_types.first.id}%5D=1#select-tickets"
    assert_equal 0, @event.orders.count
  end

  test 'create_checkout_tool sells hidden ticket types only with their secret link' do
    covers 'integrations/requirements-secret-ticket-type-and-discount-code@8423d7', 'integrations/checkout-secret-ticket-type@de93f5'
    create_event(prices: [0])
    hidden = @event.ticket_types.create!(name: 'Secret', price: 0, quantity: 5, hidden: true)

    rpc, = create_checkout(quantities: { hidden.id.to_s => 1 })
    assert_includes tool_text(rpc), 'Ticket type not found'

    rpc, = create_checkout(quantities: { hidden.id.to_s => 1 }, secret_ticket_type_id: 'not-the-link')
    assert_includes tool_text(rpc), "doesn't unlock a ticket type"
    assert_equal 0, @event.orders.count

    link = "#{ENV['BASE_URI']}/e/#{@event.slug}?ticket_type_id=#{hidden.public_id}"
    requirements = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug, secret_ticket_type_id: link })))
    listed = requirements['ticket_types'].find { |ticket_type| ticket_type['id'] == hidden.id.to_s }
    assert listed['hidden']

    _rpc, order = create_checkout(quantities: { hidden.id.to_s => 1 }, secret_ticket_type_id: link)
    assert_equal 'complete', order['status']
    assert_equal ['Secret'], order['tickets'].pluck('ticket_type')
  end

  test 'create_checkout_tool books range and pay-what-you-want tickets at the price the buyer chose' do
    covers 'events/pay-any-amount-when-price-blank@778398', 'integrations/checkout-prices-chosen-by-buyer@e549fb'
    create_event(prices: ['10-100', nil])
    range = @event.ticket_types.detect(&:range)
    pay_what_you_want = @event.ticket_types.detect { |ticket_type| !ticket_type.range }

    rpc, = create_checkout(quantities: { range.id.to_s => 1 }, prices: { range.id.to_s => 150 })
    assert_includes tool_text(rpc), "#{range.name} (from £10 to £100)"
    assert_equal 0, @event.orders.count

    order = nil
    with_stubbed_stripe_session do
      _rpc, order = create_checkout(quantities: { range.id.to_s => 2, pay_what_you_want.id.to_s => 1 },
                                    prices: { range.id.to_s => 25, pay_what_you_want.id.to_s => 7.5 })
    end
    assert_equal 'awaiting_payment', order['status']
    assert_equal [25.0, 25.0, 7.5], order['tickets'].pluck('price').sort.reverse
    assert_equal 57.5, order['total']
  end

  test 'create_checkout_tool applies a discount code' do
    covers 'integrations/requirements-discount-codes-and-terms@332fd9', 'integrations/requirements-secret-ticket-type-and-discount-code@8423d7', 'integrations/order-includes-discounts-credit-donation@873ca3'
    create_event(prices: [10, 20])
    early, late = @event.ticket_types.sort_by(&:price)
    early.set(name: 'Early bird')
    @event.discount_codes.create!(code: 'HALF', percentage_discount: 50, maximum_uses: 1)
    @event.discount_codes.create!(code: 'EARLY', percentage_discount: 10, filter: 'early')

    requirements = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug, discount_code: 'early' })))
    assert requirements['discount_codes']
    assert_equal({ 'code' => 'EARLY', 'valid' => true, 'percentage_discount' => 10, 'fixed_discount' => nil, 'fixed_discount_currency' => nil, 'ticket_type_ids' => [early.id.to_s] },
                 requirements['discount_code'])

    rpc, = create_checkout(quantities: { early.id.to_s => 1 }, discount_code: 'NOPE')
    assert_includes tool_text(rpc), 'The discount code NOPE is not valid for this event.'

    rpc, = create_checkout(quantities: { late.id.to_s => 1 }, discount_code: 'early')
    assert_includes tool_text(rpc), 'only applies to ticket types whose names include early'
    assert_equal 0, @event.orders.count

    order = nil
    with_stubbed_stripe_session do
      _rpc, order = create_checkout(quantities: { early.id.to_s => 1, late.id.to_s => 1 }, discount_code: 'half')
    end
    assert_equal 15.0, order['total']
    assert_equal({ 'discount_code' => 'HALF', 'percentage_discount' => 50 }, order['discounts'])

    rpc, = create_checkout(quantities: { early.id.to_s => 1 }, discount_code: 'HALF')
    assert_includes tool_text(rpc), 'The discount code HALF has been used up.'
  end

  test 'create_checkout_tool pays with the payment method the buyer chose' do
    covers 'integrations/checkout-payment-method@c5f11b', 'integrations/paid-bookings-checkout-url-pay-by@0961c7'
    create_event(prices: [10])
    @organisation.set(paypal_client_id: 'client', paypal_secret: 'secret')
    quantities = { @event.ticket_types.first.id.to_s => 1 }

    rpc, = create_checkout(quantities: quantities, payment_method: 'evm')
    assert_includes tool_text(rpc), 'Choose one of the payment methods agents can use for this event: stripe, paypal.'

    rpc, = create_checkout(quantities: quantities, payment_method: 'rsvp')
    assert_includes tool_text(rpc), 'rsvp is only for bookings with nothing left to pay'
    assert_equal 0, @event.orders.count

    order = nil
    EventPaymentMethod::Paypal.stub(:call, ->(**) { { redirect_url: 'https://www.paypal.com/checkoutnow?token=test' }.to_json }) do
      _rpc, order = create_checkout(quantities: quantities, payment_method: 'paypal')
    end
    assert_equal 'awaiting_payment', order['status']
    assert_equal 'https://www.paypal.com/checkoutnow?token=test', order['checkout_url']
  end

  test 'create_checkout_tool updates the profile of the account it books for with an API key' do
    covers 'integrations/checkout-books-as-you-with-api-key@06e7e4'
    create_event(prices: [0])
    @organisation.update_attributes!(collect_phone: true)
    buyer_headers
    name = @buyer.name

    _rpc, order = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 }, buyer: { name: 'Ignored', phone: '+447700900000' })
    assert_equal 'complete', order['status']
    @buyer.reload
    assert_equal '+447700900000', @buyer.phone
    assert_equal name, @buyer.name
  end

  test 'create_checkout_tool refuses a phone number without its country code' do
    create_event(prices: [0])
    @organisation.update_attributes!(collect_phone: true)

    rpc, = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 }, buyer: { name: 'Ignored', phone: '07700900000' })
    assert rpc.dig('result', 'isError')
    assert_includes tool_text(rpc), 'Phone number must start with the + country code'
    assert_equal 0, @event.orders.count
  end

  test 'create_checkout_tool records the cohost and affiliate the buyer came through' do
    covers 'integrations/checkout-attribution@65a63c'
    create_event(prices: [0])
    affiliate = FactoryBot.create(:account)

    _rpc, order = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 },
                                  attribution: { affiliate_type: 'Account', affiliate_id: affiliate.id.to_s, utm_source: 'newsletter', unknown: 'ignored' })

    record = Order.find(order['order_id'])
    assert_equal affiliate, record.affiliate
  end

  test 'join_waitlist_tool joins a sold-out ticket type waitlist' do
    covers 'events/ticket-type-waitlists@ac1e0a', 'integrations/requirements-public-ticket-types@b1c443', 'integrations/requirements-event-waitlist@7ebced', 'integrations/join-waitlist-sold-out-ticket-type-or-event@1c20be', 'integrations/join-waitlist-as-you-or-buyer@a2d0b1'
    create_event(prices: [10, 20], allow_ticket_type_waitlists: true)
    sold_out, on_sale = @event.ticket_types.sort_by(&:price)
    sold_out.set(quantity: 0)

    requirements = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))
    assert_equal({ sold_out.id.to_s => true, on_sale.id.to_s => false }, requirements['ticket_types'].to_h { |ticket_type| [ticket_type['id'], ticket_type['waitlist']] })
    refute requirements['event_waitlist']

    rpc = mcp_tool_call('join_waitlist_tool', arguments: { slug: @event.slug, ticket_type_id: on_sale.id.to_s, buyer: { name: 'Wait Er', email: 'waiter@example.com' } })
    assert_includes tool_text(rpc), 'not sold out'
    assert_nil Account.find_by(email: 'waiter@example.com')

    rpc = mcp_tool_call('join_waitlist_tool', arguments: { slug: @event.slug, ticket_type_id: sold_out.id.to_s })
    assert_includes tool_text(rpc), 'Provide buyer'

    2.times do
      rpc = mcp_tool_call('join_waitlist_tool', arguments: { slug: @event.slug, ticket_type_id: sold_out.id.to_s, buyer: { name: 'Wait Er', email: 'Waiter@example.com' } })
      assert_equal 'joined', JSON.parse(tool_text(rpc))['status']
    end
    assert_equal [Account.find_by(email: 'waiter@example.com')], sold_out.ticket_type_waitships.map(&:account)

    rpc = mcp_tool_call('join_waitlist_tool', arguments: { slug: @event.slug })
    assert_includes tool_text(rpc), 'Pass the ticket_type_id of one'
  end

  test "join_waitlist_tool joins a sold-out event's waitlist as the authenticated account" do
    covers 'integrations/requirements-event-waitlist@7ebced', 'integrations/join-waitlist-sold-out-ticket-type-or-event@1c20be', 'integrations/join-waitlist-as-you-or-buyer@a2d0b1'
    create_event(prices: [10])
    rpc = mcp_tool_call('join_waitlist_tool', arguments: { slug: @event.slug }, headers: buyer_headers)
    assert_includes tool_text(rpc), "isn't sold out"

    @event.ticket_types.first.set(quantity: 0)
    @event.refresh_sold_out_cache_and_notify_waitlist
    assert JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))['event_waitlist']

    rpc = mcp_tool_call('join_waitlist_tool', arguments: { slug: @event.slug }, headers: buyer_headers)
    assert_equal 'joined', JSON.parse(tool_text(rpc))['status']
    assert @event.waitships.find_by(account: @buyer)
  end

  test 'admin tools only read data' do
    covers 'integrations/admin-data-read-only@122ed7'
    tools = mcp_rpc('tools/list').dig('result', 'tools').index_by { |tool| tool['name'] }

    %w[get_me_tool get_organisation_events_tool get_organisation_followers_tool get_organisation_orders_tool get_event_orders_tool get_event_tickets_tool].each do |name|
      assert tools[name].dig('annotations', 'readOnlyHint'), name
      refute tools[name].dig('annotations', 'destructiveHint'), name
    end
  end

  test 'search tools find recent and upcoming events, organisations, gatherings and accounts' do
    covers 'integrations/emails-only-when-allowed@a6c1bb', 'integrations/search-tools@56e647', 'integrations/secret-event-found-by-slug-or-link@d9e645'
    create_event(name: 'Moonlit Drumming Circle')
    create_event(name: 'Moonlit Drumming Recap', as: :recent_event, start_time: 3.days.ago, end_time: 3.days.ago + 2.hours)
    create_event(name: 'Moonlit Drumming Archive', as: :old_event, start_time: 3.weeks.ago, end_time: 3.weeks.ago + 2.hours)
    create_event(name: 'Moonlit Drumming Secret', as: :secret_event, secret: true)
    [@event, @recent_event, @old_event, @secret_event].each { |event| event.set(browsable: true) }
    @organisation.set(name: 'Moonlit Collective')
    create_gathering(name: 'Moonlit Gathering')
    account = FactoryBot.create(:account, name: 'Moonlit Dancer')
    account.set(has_signed_in: true)

    events = JSON.parse(tool_text(mcp_tool_call('search_events_tool', arguments: { query: 'Moonlit Drumming' })))
    assert_equal [@event.id.to_s, @recent_event.id.to_s].sort, events.pluck('id').sort
    assert_equal "#{ENV['BASE_URI']}/e/#{@event.slug}", events.find { |event| event['id'] == @event.id.to_s }['url']

    organisations = JSON.parse(tool_text(mcp_tool_call('search_organisations_tool', arguments: { query: 'Moonlit' })))
    assert_equal [@organisation.slug], organisations.pluck('slug')

    gatherings = JSON.parse(tool_text(mcp_tool_call('search_gatherings_tool', arguments: { query: 'Moonlit' })))
    assert_equal [@gathering.slug], gatherings.pluck('slug')

    accounts = JSON.parse(tool_text(mcp_tool_call('search_accounts_tool', arguments: { query: 'Moonlit' })))
    assert_equal [account.username], accounts.pluck('username')
    assert_nil accounts.first['email']
  end

  test 'get tools look up organisations, gatherings and accounts by slug or username or id, and events by id' do
    covers 'integrations/emails-only-when-allowed@a6c1bb', 'integrations/look-up-by-slug-or-id@d69717', 'integrations/events-include-currency-ticket-types@18bab5'
    create_event(prices: [10])
    create_gathering
    account = FactoryBot.create(:account)
    account.set(has_signed_in: true)

    [{ slug: @organisation.slug }, { id: @organisation.id.to_s }].each do |arguments|
      assert_equal @organisation.name, JSON.parse(tool_text(mcp_tool_call('get_organisation_tool', arguments: arguments)))['name']
    end
    [{ slug: @gathering.slug }, { id: @gathering.id.to_s }].each do |arguments|
      assert_equal @gathering.name, JSON.parse(tool_text(mcp_tool_call('get_gathering_tool', arguments: arguments)))['name']
    end
    [{ username: account.username }, { id: account.id.to_s }].each do |arguments|
      payload = JSON.parse(tool_text(mcp_tool_call('get_account_tool', arguments: arguments)))
      assert_equal account.name, payload['name']
      assert_nil payload['email']
    end

    event = JSON.parse(tool_text(mcp_tool_call('get_event_tool', arguments: { id: @event.id.to_s })))
    assert_equal @event.slug, event['slug']
    assert_equal 'GBP', event['currency']
    assert_equal [@event.ticket_types.first.id.to_s], event['ticket_types'].pluck('id')

    assert_includes tool_text(mcp_tool_call('get_organisation_tool', arguments: { slug: 'no-such-organisation' })), 'Organisation not found'
  end

  test 'get_trending_events_tool returns trending upcoming events first' do
    covers 'integrations/trending-events@28cb75'
    create_event(as: :soonest, start_time: 1.day.from_now, end_time: 1.day.from_now + 1.hour)
    create_event(as: :trending_event, start_time: 2.months.from_now, end_time: 2.months.from_now + 1.hour)
    create_event(as: :without_image)
    create_event(as: :past_event, start_time: 2.days.ago, end_time: 2.days.ago + 1.hour)
    [@soonest, @trending_event, @past_event].each { |event| event.set(has_image: true, browsable: true) }
    @without_image.set(browsable: true)
    @trending_event.set(trending: true)

    events = JSON.parse(tool_text(mcp_tool_call('get_trending_events_tool', arguments: { limit: 10 })))

    assert_equal [@trending_event.id.to_s, @soonest.id.to_s], events.pluck('id')
    assert_equal @trending_event.slug, events.first['slug']
  end

  test 'get_organisation_upcoming_events_tool returns its upcoming hosted and cohosted events, soonest first' do
    covers 'integrations/organisation-upcoming-events@8f832f'
    create_event(as: :later, start_time: 2.months.from_now, end_time: 2.months.from_now + 1.hour)
    create_event(as: :past_event, start_time: 2.days.ago, end_time: 2.days.ago + 1.hour)
    create_event(as: :secret_event, secret: true)
    cohosted = FactoryBot.create(:event, organisation: FactoryBot.create(:organisation, account: FactoryBot.create(:account)),
                                         start_time: 1.week.from_now, end_time: 1.week.from_now + 1.hour)
    cohosted.cohostships.create!(organisation: @organisation)

    events = JSON.parse(tool_text(mcp_tool_call('get_organisation_upcoming_events_tool', arguments: { slug: @organisation.slug })))
    assert_equal [cohosted.id.to_s, @later.id.to_s], events.pluck('id')

    events = JSON.parse(tool_text(mcp_tool_call('get_organisation_upcoming_events_tool', arguments: { id: @organisation.id.to_s, to: 1.month.from_now.to_date.iso8601 })))
    assert_equal [cohosted.id.to_s], events.pluck('id')
  end

  test 'get_event_tool and join_waitlist_tool take a link to the event as its slug, and searches leave out secret events' do
    covers 'integrations/tools-take-event-link-as-slug@7a5e0d', 'integrations/secret-event-found-by-slug-or-link@d9e645'
    create_event(name: 'Hushed Listening Session', prices: [10], secret: true)
    @event.set(browsable: true)
    link = "#{ENV['BASE_URI']}/e/#{@event.slug}?utm_source=newsletter"

    assert_equal @event.id.to_s, JSON.parse(tool_text(mcp_tool_call('get_event_tool', arguments: { slug: link })))['id']
    assert_empty JSON.parse(tool_text(mcp_tool_call('search_events_tool', arguments: { query: 'Hushed Listening' })))

    @event.ticket_types.first.set(quantity: 0)
    @event.refresh_sold_out_cache_and_notify_waitlist
    rpc = mcp_tool_call('join_waitlist_tool', arguments: { slug: link, buyer: { name: 'Wait Er', email: 'waiter@example.com' } })
    assert_equal 'joined', JSON.parse(tool_text(rpc))['status']
    assert @event.waitships.find_by(account: Account.find_by(email: 'waiter@example.com'))
  end

  test 'get_event_checkout_requirements_tool says when sales have closed or the event is for members only' do
    covers 'integrations/requirements-bookable-and-why-not@11def2'
    create_event(prices: [10], start_time: 2.days.ago, end_time: 1.day.ago, no_sales_after_end_time: true)
    closed = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))

    refute closed['purchasable']
    assert_equal ['sales_closed'], closed['restrictions']

    activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'closed')
    create_event(prices: [10], as: :members_event, activity: activity)
    members = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @members_event.slug })))

    refute members['purchasable']
    assert_equal ['members_only'], members['restrictions']
  end

  test 'get_event_checkout_requirements_tool says which ticket types are sold out and when their sales end' do
    covers 'integrations/requirements-public-ticket-types@b1c443'
    create_event(prices: [10, 20])
    sold_out, on_sale = @event.ticket_types.sort_by(&:price)
    sold_out.set(quantity: 0)
    sales_end = 1.week.from_now.change(usec: 0)
    on_sale.set(sales_end: sales_end)

    ticket_types = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))['ticket_types'].index_by { |ticket_type| ticket_type['id'] }

    assert ticket_types[sold_out.id.to_s]['sold_out']
    refute ticket_types[on_sale.id.to_s]['sold_out']
    assert_equal sales_end, Time.zone.parse(ticket_types[on_sale.id.to_s]['sales_end'])
    assert_nil ticket_types[sold_out.id.to_s]['sales_end']
  end

  test 'get_event_checkout_requirements_tool lists the terms to accept' do
    covers 'integrations/requirements-discount-codes-and-terms@332fd9'
    create_event(prices: [0], terms_and_conditions: 'Be kind', terms_and_conditions_check_box: true)

    terms = JSON.parse(tool_text(mcp_tool_call('get_event_checkout_requirements_tool', arguments: { slug: @event.slug })))['terms']

    assert_includes terms['text'], 'Be kind'
    assert terms['must_accept']
    assert_equal "#{ENV['BASE_URI']}/terms", terms['platform_terms_url']
  end

  test 'create_checkout_tool records the cohost and passes on the UTM fields' do
    covers 'integrations/checkout-attribution@65a63c'
    create_event(prices: [10])
    cohost = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    @event.cohostships.create!(organisation: cohost)
    session = api_object(id: 'cs_test', payment_intent: 'pi_test', url: 'https://checkout.stripe.com/test')
    session_hash = nil

    order = nil
    Stripe::Checkout::Session.stub(:create, ->(hash, *) { session_hash = hash; session }) do
      _rpc, order = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 },
                                    attribution: { cohost: cohost.slug, utm_source: 'newsletter', utm_medium: 'email', utm_campaign: 'spring' })
    end

    # The cohost is recorded as the order's affiliate, as the checkout form records it
    assert_equal cohost, Order.find(order['order_id']).affiliate
    assert_includes session_hash[:success_url], 'utm_source=newsletter&utm_medium=email&utm_campaign=spring'
  end

  test 'create_checkout_tool says unpaid orders are released after an hour' do
    covers 'integrations/paid-bookings-checkout-url-pay-by@0961c7'
    create_event(prices: [10])
    session_hash = nil

    order = nil
    Stripe::Checkout::Session.stub(:create, ->(hash, *) { session_hash = hash; api_object(id: 'cs_test', payment_intent: 'pi_test', url: 'https://checkout.stripe.com/test') }) do
      _rpc, order = create_checkout(quantities: { @event.ticket_types.first.id.to_s => 1 })
    end

    created_at = Order.find(order['order_id']).created_at
    assert_equal (created_at + 1.hour).to_i, Time.zone.parse(order['pay_by']).to_i
    # The payment page closes then too
    assert_equal (created_at + 1.hour).to_i, session_hash[:expires_at]
  end

  test 'get_event_tickets_tool hides ordered_for_email from event admins who cannot view emails' do
    covers 'integrations/emails-only-when-allowed@a6c1bb', 'integrations/ticket-emails-may-be-empty@54ad94'
    facilitator = FactoryBot.create(:account)
    attendee = FactoryBot.create(:account)
    create_event(prices: [0], show_emails: false)
    @event.event_facilitations.create!(account: facilitator)
    order = @event.orders.create!(account: attendee, currency: @event.currency, value: 0, payment_completed: true, original_description: 'MCP privacy test')
    @event.tickets.create!(account: attendee, order: order, ticket_type: @event.ticket_types.first, payment_completed: true, name: 'Bob Guest', email: 'bob.guest@example.com')

    ticket = JSON.parse(tool_text(mcp_tool_call('get_event_tickets_tool', arguments: { slug: @event.slug }, headers: { 'Authorization' => "Bearer #{facilitator.api_key}" }))).first
    assert_equal 'Bob Guest', ticket['ordered_for_name']
    assert_equal '', ticket['ordered_for_email']

    ticket = JSON.parse(tool_text(mcp_tool_call('get_event_tickets_tool', arguments: { slug: @event.slug }, headers: { 'Authorization' => "Bearer #{@account.api_key}" }))).first
    assert_equal 'bob.guest@example.com', ticket['ordered_for_email']
  end
end
