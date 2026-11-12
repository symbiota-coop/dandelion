require_relative '../test_config'
require_relative '../helpers/mcp_helpers'

# The MCP server: authentication, and the tools that read events, orders, organisations and accounts
class McpTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include McpHelpers

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
