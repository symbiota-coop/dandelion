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

  test 'event order and ticket tools require an event slug or id' do
    create_event_with_order_and_ticket
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    %w[get_event_orders_tool get_event_tickets_tool].each do |name|
      rpc = mcp_tool_call(name, headers: headers)

      assert_equal 200, last_response.status
      assert rpc.dig('result', 'isError')
      assert_includes tool_text(rpc), 'Provide event slug or id'
    end
  end

  test 'event order and ticket tools return not found for unknown events' do
    create_event_with_order_and_ticket
    headers = { 'Authorization' => "Bearer #{@account.api_key}" }

    %w[get_event_orders_tool get_event_tickets_tool].each do |name|
      rpc = mcp_tool_call(name, arguments: { slug: 'does-not-exist' }, headers: headers)

      assert_equal 200, last_response.status
      assert rpc.dig('result', 'isError')
      assert_includes tool_text(rpc), 'Event not found'
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
end
