require_relative '../test_config'

class ZapierTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # Zapier signs in with the account's API key in the query string
  def zapier_get(path, account: @account, **params)
    get path, params.merge(api_key: account.api_key)
    JSON.parse(last_response.body) if last_response.ok?
  end

  def complete_order(event, account, **attributes)
    event.orders.create!(account: account, currency: event.currency, value: 0, payment_completed: true, original_description: 'Zapier test order', **attributes)
  end

  def cohosted_event
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    event = FactoryBot.create(:event, organisation: other_organisation, prices: [0])
    event.cohostships.create!(organisation: @organisation)
    event
  end

  test 'GET /z returns the account the API key belongs to, the same key MCP takes' do
    covers 'integrations/zapier-and-mcp-same-api-key@a1a235', 'integrations/zapier-identifies-account-and-lists-events@bb9bc2', 'integrations/account-returns-authenticated-account@f5b358', 'integrations/zapier-get-account@fb0cbb'
    account = FactoryBot.create(:account)

    payload = zapier_get('/z', account: account)

    assert_equal 200, last_response.status
    assert_equal({ 'id' => account.id.to_s, 'name' => account.name, 'username' => account.username, 'email' => account.email,
                   'url' => "#{ENV['BASE_URI']}/u/#{account.username}" }, payload)

    header 'Content-Type', 'application/json'
    header 'Accept', 'application/json, text/event-stream'
    header 'Authorization', "Bearer #{account.api_key}"
    post '/mcp', { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'get_me_tool', arguments: {} } }.to_json
    assert_equal payload, JSON.parse(JSON.parse(last_response.body).dig('result', 'content', 0, 'text'))
  end

  test 'GET /z refuses an unknown API key or none' do
    covers 'integrations/zapier-get-account@fb0cbb'
    covers_route 'GET /z'
    get '/z', api_key: 'not-a-real-key'
    assert_equal 403, last_response.status

    get '/z'
    assert last_response.redirect?
  end

  test 'Zapier endpoints only read data' do
    covers 'integrations/admin-data-read-only@122ed7'
    create_event(prices: [0])

    %w[/z /z/organisation_events /z/organisation_followers /z/organisation_orders /z/organisation_event_orders /z/organisation_event_tickets].each do |path|
      %i[post put patch delete].each do |verb|
        send(verb, path, slug: @organisation.slug, api_key: @account.api_key)
        assert_equal 405, last_response.status, "#{verb.upcase} #{path}"
      end
    end
  end

  test 'organisation events include cohosted events, most recent first, by slug or id' do
    covers 'integrations/zapier-identifies-account-and-lists-events@bb9bc2', 'integrations/organisation-events-returns-events@1b8177', 'integrations/zapier-organisation-events-params@8ab821'
    covers_route 'GET /z/organisation_events'
    create_event(prices: [0], start_time: 2.months.from_now, end_time: 2.months.from_now + 1.hour)
    create_event(prices: [0], as: :earlier_event, start_time: 1.week.ago, end_time: 1.week.ago + 1.hour)
    cohosted = cohosted_event
    cohosted.set(start_time: 1.month.from_now, end_time: 1.month.from_now + 1.hour)
    FactoryBot.create(:event, organisation: FactoryBot.create(:organisation, account: FactoryBot.create(:account)), prices: [0])
    expected = [@event.id.to_s, cohosted.id.to_s, @earlier_event.id.to_s]

    [{ slug: @organisation.slug }, { id: @organisation.id.to_s }, { organisation_slug: @organisation.slug }, { organisation_id: @organisation.id.to_s }].each do |params|
      events = zapier_get('/z/organisation_events', **params)
      assert_equal 200, last_response.status
      assert_equal(expected, events.map { |event| event['id'] }, params.inspect)
    end
    events = zapier_get('/z/organisation_events', slug: @organisation.slug)
    assert_equal @event.slug, events.first['slug']
    assert_includes events.first['name'], @event.name
  end

  test 'organisation endpoints are only for its admins' do
    covers 'integrations/organisation-events-returns-events@1b8177', 'integrations/event-orders-returns-completed-orders@2599ad', 'integrations/event-tickets-returns-completed-tickets@2c4319'
    create_event(prices: [0])
    stranger = FactoryBot.create(:account)

    %w[/z/organisation_events /z/organisation_followers /z/organisation_orders].each do |path|
      assert_nil zapier_get(path, account: stranger, slug: @organisation.slug)
      assert last_response.redirect?, path
    end
    %w[/z/organisation_event_orders /z/organisation_event_tickets].each do |path|
      assert_nil zapier_get(path, account: stranger, slug: @event.slug)
      assert last_response.redirect?, path
    end
  end

  test 'organisation followers are those from the last 24 hours, most recent first' do
    covers 'integrations/zapier-new-follower@d5199e', 'integrations/organisation-followers-last-24-hours@8e8cf5', 'integrations/zapier-organisation-followers-params@fd94e6'
    covers_route 'GET /z/organisation_followers'
    create_organisation
    @organisation.organisationships.find_by(account: @account).set(created_at: 2.days.ago)
    older, newer, stale = Array.new(3) { FactoryBot.create(:account) }.map { |account| @organisation.organisationships.create!(account: account) }
    older.set(created_at: 3.hours.ago)
    newer.set(created_at: 1.hour.ago)
    stale.set(created_at: 25.hours.ago)

    [{ slug: @organisation.slug }, { id: @organisation.id.to_s }, { organisation_slug: @organisation.slug }, { organisation_id: @organisation.id.to_s }].each do |params|
      followers = zapier_get('/z/organisation_followers', **params)
      assert_equal 200, last_response.status
      assert_equal([newer.id.to_s, older.id.to_s], followers.map { |follower| follower['id'] }, params.inspect)
    end
    follower = zapier_get('/z/organisation_followers', slug: @organisation.slug).first
    assert_equal newer.account.name, follower['name']
    assert_equal newer.account.email, follower['email']
  end

  test 'organisation orders cover hosted and cohosted events, including ones created later' do
    covers 'integrations/zapier-order-confirmed-organisation@93fe70', 'integrations/organisation-orders-most-recently-completed@db1be3', 'integrations/zapier-organisation-orders-params@75c428'
    covers_route 'GET /z/organisation_orders'
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    hosted_order = complete_order(@event, attendee)
    cohosted_order = complete_order(cohosted_event, attendee)
    complete_order(FactoryBot.create(:event, organisation: FactoryBot.create(:organisation, account: FactoryBot.create(:account)), prices: [0]), attendee)
    @event.orders.create!(account: attendee, currency: @event.currency, value: 10, payment_completed: false, original_description: 'Zapier incomplete order')

    [{ slug: @organisation.slug }, { id: @organisation.id.to_s }, { organisation_slug: @organisation.slug }, { organisation_id: @organisation.id.to_s }].each do |params|
      orders = zapier_get('/z/organisation_orders', **params)
      assert_equal 200, last_response.status
      assert_equal([cohosted_order.id.to_s, hosted_order.id.to_s], orders.map { |order| order['id'] }, params.inspect)
    end

    # The same Zap picks up an event created after it was set up
    create_event(prices: [0], as: :later_event)
    later_order = complete_order(@later_event, attendee)
    orders = zapier_get('/z/organisation_orders', slug: @organisation.slug)
    assert_equal later_order.id.to_s, orders.first['id']
    assert_equal @later_event.slug, orders.first['event_slug']
  end

  test 'organisation orders are the 100 most recently completed' do
    covers 'integrations/organisation-orders-most-recently-completed@db1be3'
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    oldest = complete_order(@event, attendee)
    oldest.set(completed_at: 1.day.ago)
    orders = Array.new(100) { complete_order(@event, attendee) }

    ids = zapier_get('/z/organisation_orders', slug: @organisation.slug).map { |order| order['id'] }

    assert_equal 100, ids.length
    refute_includes ids, oldest.id.to_s
    assert_equal orders.last.id.to_s, ids.first
  end

  test 'event orders are the completed ones, most recent first, by slug or id' do
    covers 'integrations/zapier-order-confirmed@b66f74', 'integrations/event-orders-returns-completed-orders@2599ad', 'integrations/zapier-event-orders-params@e37544'
    covers_route 'GET /z/organisation_event_orders'
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    older = complete_order(@event, attendee, via: 'newsletter')
    older.set(created_at: 1.day.ago)
    newer = complete_order(@event, attendee)
    @event.orders.create!(account: attendee, currency: @event.currency, value: 10, payment_completed: false, original_description: 'Zapier incomplete order')

    [{ slug: @event.slug }, { id: @event.id.to_s }, { event_slug: @event.slug }, { event_id: @event.id.to_s }].each do |params|
      orders = zapier_get('/z/organisation_event_orders', **params)
      assert_equal 200, last_response.status
      assert_equal([newer.id.to_s, older.id.to_s], orders.map { |order| order['id'] }, params.inspect)
    end
    order = zapier_get('/z/organisation_event_orders', slug: @event.slug).last
    assert_equal attendee.email, order['email']
    assert_equal 'newsletter', order['via']
    assert_equal @event.id.to_s, order['event_id']
  end

  test 'event tickets are the completed ones, most recent first, by slug or id' do
    covers 'integrations/zapier-ticket-confirmed@e8169c', 'integrations/event-tickets-returns-completed-tickets@2c4319', 'integrations/zapier-event-tickets-params@6c1422'
    covers_route 'GET /z/organisation_event_tickets'
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    order = complete_order(@event, attendee)
    ticket_type = @event.ticket_types.first
    older = @event.tickets.create!(account: attendee, order: order, ticket_type: ticket_type, payment_completed: true, name: 'Bob Guest', email: 'bob.guest@example.com')
    older.set(created_at: 1.day.ago)
    newer = @event.tickets.create!(account: attendee, order: order, ticket_type: ticket_type, payment_completed: true)
    # A free ticket completes as it's made
    @event.tickets.create!(account: attendee, order: order, ticket_type: ticket_type).set(payment_completed: false)

    [{ slug: @event.slug }, { id: @event.id.to_s }, { event_slug: @event.slug }, { event_id: @event.id.to_s }].each do |params|
      tickets = zapier_get('/z/organisation_event_tickets', **params)
      assert_equal 200, last_response.status
      assert_equal([newer.id.to_s, older.id.to_s], tickets.map { |ticket| ticket['id'] }, params.inspect)
    end
    ticket = zapier_get('/z/organisation_event_tickets', slug: @event.slug).last
    assert_equal attendee.email, ticket['email']
    assert_equal 'Bob Guest', ticket['ordered_for_name']
    assert_equal 'bob.guest@example.com', ticket['ordered_for_email']
    assert_equal ticket_type.name, ticket['ticket_type']
    assert_equal order.id.to_s, ticket['order_id']
  end

  test 'event orders and tickets leave out emails the admin cannot view' do
    covers 'integrations/emails-only-when-allowed@a6c1bb', 'integrations/order-email-may-be-empty@d03f03', 'integrations/ticket-emails-may-be-empty@54ad94'
    facilitator = FactoryBot.create(:account)
    attendee = FactoryBot.create(:account, name: 'Hidden Email')
    create_event(prices: [0], show_emails: false)
    @event.event_facilitations.create!(account: facilitator)
    order = complete_order(@event, attendee)
    @event.tickets.create!(account: attendee, order: order, ticket_type: @event.ticket_types.first, payment_completed: true, name: 'Bob Guest', email: 'bob.guest@example.com')

    orders = zapier_get('/z/organisation_event_orders', account: facilitator, slug: @event.slug)
    tickets = zapier_get('/z/organisation_event_tickets', account: facilitator, slug: @event.slug)

    assert_equal 'Hidden Email', orders.first['name']
    assert_equal '', orders.first['email']
    assert_equal 'Hidden Email', tickets.first['name']
    assert_equal '', tickets.first['email']
    assert_equal 'Bob Guest', tickets.first['ordered_for_name']
    assert_equal '', tickets.first['ordered_for_email']

    # The organisation's admin can view them
    tickets = zapier_get('/z/organisation_event_tickets', slug: @event.slug)
    assert_equal attendee.email, tickets.first['email']
    assert_equal 'bob.guest@example.com', tickets.first['ordered_for_email']
  end
end
