require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class ApiTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def authorize_api(account)
    header 'Authorization', "Bearer #{account.api_key}"
  end

  def api_post(path, account, body = {})
    authorize_api(account) if account
    header 'Content-Type', 'application/json'
    post path, body.to_json
    JSON.parse(last_response.body)
  end

  def api_find(resource, account, body = {})
    api_post("/api/#{resource}/find", account, body)
  end

  def create_order_for(event, account, **attrs)
    event.ticket_types.first.set(quantity: 100)
    order = event.orders.create!(account: account, currency: event.currency, value: 0, payment_completed: true, original_description: 'API test order', **attrs)
    event.tickets.create!(account: account, order: order, ticket_type: event.ticket_types.first, payment_completed: true)
    order
  end

  test 'requests without an API key are rejected' do
    get '/api/resources'

    assert_equal 401, last_response.status
    assert_equal 'Bearer', last_response['WWW-Authenticate']
    assert_equal 'unauthorized', JSON.parse(last_response.body)['error']
  end

  test 'requests with an invalid API key are rejected' do
    header 'Authorization', 'Bearer not-a-real-key'
    post '/api/events/find', {}.to_json

    assert_equal 401, last_response.status
    assert_equal 'invalid_token', JSON.parse(last_response.body)['error']
  end

  test 'session cookies do not authenticate API requests' do
    account = FactoryBot.create(:account)
    sign_in_with_rack(account)
    get '/api/resources'

    assert_equal 401, last_response.status
  end

  test 'resources are listed with their fields' do
    account = FactoryBot.create(:account)
    authorize_api(account)
    get '/api/resources'
    resources = JSON.parse(last_response.body)

    assert_equal 200, last_response.status
    assert_equal(Dandelion::API::RESOURCE_DEFINITIONS.keys, resources.map { |r| r['name'] })
    accounts = resources.find { |r| r['name'] == 'accounts' }
    refute_includes accounts['fields'], 'email'
  end

  test 'events returns public events, plus secret and locked events you administer' do
    create_event(as: :public_event)
    create_event(as: :secret_event, secret: true)
    create_event(as: :locked_event, locked: true)
    stranger = FactoryBot.create(:account)
    facilitator = FactoryBot.create(:account)
    @secret_event.event_facilitations.create!(account: facilitator)

    stranger_ids = api_find('events', stranger)['data'].map { |e| e['id'] }
    assert_equal 200, last_response.status
    assert_includes stranger_ids, @public_event.id.to_s
    refute_includes stranger_ids, @secret_event.id.to_s
    refute_includes stranger_ids, @locked_event.id.to_s

    admin_ids = api_find('events', @account)['data'].map { |e| e['id'] }
    assert_includes admin_ids, @secret_event.id.to_s
    assert_includes admin_ids, @locked_event.id.to_s

    facilitator_ids = api_find('events', facilitator)['data'].map { |e| e['id'] }
    assert_includes facilitator_ids, @secret_event.id.to_s
    refute_includes facilitator_ids, @locked_event.id.to_s
  end

  test 'filters convert ids and dates, and fields limits the output' do
    create_event(as: :soon, start_time: 2.days.from_now, end_time: 3.days.from_now)
    create_event(as: :later, start_time: 2.months.from_now, end_time: (2.months + 1.day).from_now)
    FactoryBot.create(:event)

    result = api_find('events', @account, {
                        filter: { organisation_id: @organisation.id.to_s, start_time: { '$gte' => 1.month.from_now.iso8601 } },
                        fields: %w[name url]
                      })

    assert_equal 200, last_response.status
    assert_equal([@later.id.to_s], result['data'].map { |e| e['id'] })
    assert_equal %w[id name url], result['data'].first.keys
    assert_equal "#{ENV['BASE_URI']}/e/#{@later.slug}", result['data'].first['url']
  end

  test 'logical operators, regex, sort, limit and has_more work' do
    create_event(as: :alpha, name: 'Alpha gathering')
    create_event(as: :beta, name: 'Beta gathering')
    create_event(as: :gamma, name: 'Gamma meetup')

    result = api_find('events', @account, {
                        filter: { '$or' => [{ name: { '$regex' => 'gathering', '$options' => 'i' } }, { slug: @gamma.slug }] },
                        sort: { name: 'desc' },
                        limit: 2
                      })

    assert_equal 200, last_response.status
    assert_equal(['Gamma meetup', 'Beta gathering'], result['data'].map { |e| e['name'] })
    assert result['has_more']

    result = api_find('events', @account, { filter: { name: { '$regex' => 'gathering', '$options' => 'i' } }, sort: { name: 'desc' }, limit: 2, skip: 1 })
    assert_equal(['Alpha gathering'], result['data'].map { |e| e['name'] })
    refute result['has_more']
  end

  test 'count returns the number of matching records' do
    create_event(as: :first_event)
    create_event(as: :second_event)

    result = api_post('/api/events/count', @account, { filter: { organisation_id: @organisation.id.to_s } })

    assert_equal 200, last_response.status
    assert_equal 2, result['count']
  end

  test 'get returns a single record within the resource scope' do
    create_event(as: :public_event)
    create_event(as: :secret_event, secret: true)
    authorize_api(FactoryBot.create(:account))

    get "/api/events/#{@public_event.id}"
    assert_equal 200, last_response.status
    assert_equal @public_event.name, JSON.parse(last_response.body)['name']

    get "/api/events/#{@secret_event.id}"
    assert_equal 404, last_response.status

    authorize_api(@account)
    get "/api/events/#{@secret_event.id}"
    assert_equal 200, last_response.status
    assert JSON.parse(last_response.body)['secret']
  end

  test 'disallowed operators and fields are rejected' do
    account = FactoryBot.create(:account)
    {
      { filter: { '$where' => 'sleep(1000)' } } => '$where',
      { filter: { name: { '$where' => 'true' } } } => '$where',
      { filter: { '$expr' => { '$eq' => [1, 1] } } } => '$expr',
      { filter: { email: 'someone@example.com' } } => 'Cannot filter by email',
      { filter: { username: { '$regex' => 'a' * 201 } } } => '$regex',
      { filter: { created_at: { '$regex' => '2026' } } } => 'text fields',
      { filter: { name: { 'nested' => 'doc' } } } => 'not allowed',
      { filter: { name: { '$in' => [{ '$gt' => '' }] } } } => 'Invalid value',
      { filter: 'name' } => 'filter must be an object',
      { sort: { email: 1 } } => 'Cannot sort by email',
      { fields: %w[email] } => 'Unknown fields: email',
      { skip: -1 } => 'skip'
    }.each do |body, message|
      result = api_find('accounts', account, body)

      assert_equal 400, last_response.status, "Expected #{body.inspect} to be rejected"
      assert_includes result['error_description'], message
    end
  end

  test 'deeply nested filters are rejected' do
    account = FactoryBot.create(:account)
    filter = { name: 'x' }
    7.times { filter = { '$and' => [filter] } }

    result = api_find('accounts', account, { filter: filter })

    assert_equal 400, last_response.status
    assert_includes result['error_description'], 'nested too deeply'
  end

  test 'unknown resources return 404' do
    account = FactoryBot.create(:account)

    result = api_find('stripe_charges', account)

    assert_equal 404, last_response.status
    assert_includes result['error_description'], 'Unknown resource'
  end

  test 'invalid JSON bodies are rejected' do
    account = FactoryBot.create(:account)
    authorize_api(account)
    header 'Content-Type', 'application/json'
    post '/api/events/find', '{not json'

    assert_equal 400, last_response.status
  end

  test 'accounts returns public accounts, plus your own, without emails' do
    visible = FactoryBot.create(:account, name: 'Visible Person')
    visible.set(has_signed_in: true)
    hidden = FactoryBot.create(:account, name: 'Hidden Person')
    hidden.set(has_signed_in: true, hidden: true)
    filter = { name: { '$in' => ['Visible Person', 'Hidden Person'] } }

    result = api_find('accounts', visible, { filter: filter })
    assert_equal(['Visible Person'], result['data'].map { |a| a['name'] })
    refute result['data'].first.key?('email')

    result = api_find('accounts', hidden, { filter: filter, sort: { name: 'asc' } })
    assert_equal(['Hidden Person', 'Visible Person'], result['data'].map { |a| a['name'] })
  end

  test 'gatherings returns listed gatherings, plus gatherings you are a member of' do
    create_gathering(name: 'Listed Gathering', listed: true)
    listed = @gathering
    unlisted = FactoryBot.create(:gathering, name: 'Unlisted Gathering', listed: false, account: @account)
    member = FactoryBot.create(:account)
    unlisted.memberships.create!(account: member)
    stranger = FactoryBot.create(:account)
    filter = { id: { '$in' => [listed.id.to_s, unlisted.id.to_s] } }

    assert_equal([listed.id.to_s], api_find('gatherings', stranger, { filter: filter })['data'].map { |g| g['id'] })
    assert_equal([listed.id.to_s, unlisted.id.to_s].sort, api_find('gatherings', member, { filter: filter })['data'].map { |g| g['id'] }.sort)
  end

  test 'orders and tickets return your own records, including incomplete orders' do
    create_event(prices: [0])
    alice = FactoryBot.create(:account)
    bob = FactoryBot.create(:account)
    alice_order = create_order_for(@event, alice)
    alice_incomplete = @event.orders.create!(account: alice, currency: @event.currency, value: 0, payment_completed: false, original_description: 'API test incomplete order')
    create_order_for(@event, bob)

    orders = api_find('orders', alice)
    tickets = api_find('tickets', alice)

    assert_equal([alice_order.id.to_s, alice_incomplete.id.to_s].sort, orders['data'].map { |o| o['id'] }.sort)
    assert_equal alice.email, orders['data'].first['email']
    assert_equal([alice_order.id.to_s], tickets['data'].map { |t| t['order_id'] })
    assert_equal alice.email, tickets['data'].first['email']

    escaped = api_find('orders', bob, { filter: { '$or' => [{ id: alice_order.id.to_s }, { account_id: alice.id.to_s }] } })
    assert_equal 200, last_response.status
    assert_empty escaped['data']
  end

  test 'tickets include tickets in orders you placed for someone else' do
    create_event(prices: [0])
    buyer = FactoryBot.create(:account)
    friend = FactoryBot.create(:account)
    @event.ticket_types.first.set(quantity: 100)
    order = @event.orders.create!(account: buyer, currency: @event.currency, value: 0, payment_completed: true, original_description: 'API test gift order')
    ticket = @event.tickets.create!(account: friend, order: order, ticket_type: @event.ticket_types.first, payment_completed: true, name: 'Friend', email: 'friend@example.com')

    tickets = api_find('tickets', buyer)['data']

    assert_equal([ticket.id.to_s], tickets.map { |t| t['id'] })
    assert_equal 'friend@example.com', tickets.first['ordered_for_email']
    assert_equal '', tickets.first['email']
  end

  test 'orders and tickets include completed records for events you administer' do
    create_event(prices: [0])
    attendee = FactoryBot.create(:account, name: 'Ada Lovelace')
    order = create_order_for(@event, attendee)
    @event.orders.create!(account: attendee, currency: @event.currency, value: 0, payment_completed: false, original_description: 'API test incomplete order')
    other_event = FactoryBot.create(:event, prices: [0])
    create_order_for(other_event, attendee)

    orders = api_find('orders', @account)
    tickets = api_find('tickets', @account, { filter: { event_id: @event.id.to_s } })

    assert_equal([order.id.to_s], orders['data'].map { |o| o['id'] })
    assert_equal attendee.email, orders['data'].first['email']
    assert_equal 'Ada Lovelace', orders['data'].first['name']
    assert_equal([order.id.to_s], tickets['data'].map { |t| t['order_id'] })
    assert_equal attendee.email, tickets['data'].first['email']

    stranger = FactoryBot.create(:account)
    assert_empty api_find('orders', stranger)['data']
    assert_empty api_find('tickets', stranger)['data']
  end

  test 'orders hide emails from event admins who cannot view them' do
    facilitator = FactoryBot.create(:account)
    attendee = FactoryBot.create(:account, name: 'Hidden Email')
    create_event(prices: [0], show_emails: false)
    @event.event_facilitations.create!(account: facilitator)
    create_order_for(@event, attendee)

    orders = api_find('orders', facilitator)
    tickets = api_find('tickets', facilitator)

    assert_equal 'Hidden Email', orders['data'].first['name']
    assert_equal '', orders['data'].first['email']
    assert_equal '', tickets['data'].first['email']

    api_find('orders', facilitator, { filter: { email: attendee.email } })
    assert_equal 400, last_response.status
  end

  test 'organisationships returns your own, plus followers of organisations you administer' do
    create_organisation
    follower = FactoryBot.create(:account)
    follower.organisationships.create!(organisation: @organisation)
    other_organisation = FactoryBot.create(:organisation)
    FactoryBot.create(:account).organisationships.create!(organisation: other_organisation)

    result = api_find('organisationships', @account, { filter: { account_id: follower.id.to_s } })

    assert_equal 1, result['data'].length
    assert_equal follower.email, result['data'].first['email']
    assert_equal @organisation.id.to_s, result['data'].first['organisation_id']

    everything = api_find('organisationships', @account)
    assert(everything['data'].all? { |f| f['organisation_id'] == @organisation.id.to_s })

    own = api_find('organisationships', follower)['data']
    assert_equal([follower.id.to_s], own.map { |f| f['account_id'] })
  end

  test 'readable_by without an account only returns public rows' do
    create_event(as: :public_event, prices: [0])
    create_event(as: :secret_event, secret: true)
    create_order_for(@public_event, FactoryBot.create(:account))

    event_ids = Event.readable_by(nil).pluck(:id)
    assert_includes event_ids, @public_event.id
    refute_includes event_ids, @secret_event.id
    assert_empty Order.readable_by(nil).to_a
    assert_empty Ticket.readable_by(nil).to_a
    assert_empty Organisationship.readable_by(nil).to_a
  end

  test 'Event.administered_by matches Event.admin? for every route to adminship' do
    create_full_event_hierarchy
    other_event = FactoryBot.create(:event)
    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    member = ->(organisation, **attrs) { FactoryBot.create(:account).tap { |a| a.organisationships.create!(organisation: organisation, unsubscribed: false, **attrs) } }

    admins = {
      creator: FactoryBot.create(:account).tap { |a| @event.set(account_id: a.id) },
      organiser: FactoryBot.create(:account).tap { |a| @event.set(organiser_id: a.id) },
      coordinator: FactoryBot.create(:account).tap { |a| @event.set(coordinator_id: a.id) },
      revenue_sharer: FactoryBot.create(:account).tap { |a| @event.set(revenue_sharer_id: a.id) },
      facilitator: FactoryBot.create(:account).tap { |a| @event.event_facilitations.create!(account: a) },
      organisation_admin: member.call(@organisation, admin: true),
      event_manager: member.call(@organisation, event_manager: true),
      activity_admin: FactoryBot.create(:account).tap { |a| @activity.activityships.create!(account: a, admin: true, unsubscribed: false) },
      local_group_admin: FactoryBot.create(:account).tap { |a| @local_group.local_groupships.create!(account: a, admin: true, unsubscribed: false) },
      cohost_event_manager: member.call(cohost, event_manager: true),
      site_admin: FactoryBot.create(:account).tap { |a| a.set(admin: true) }
    }
    non_admins = {
      follower: member.call(@organisation),
      activity_member: FactoryBot.create(:account).tap { |a| @activity.activityships.create!(account: a, unsubscribed: false) },
      cohost_follower: member.call(cohost),
      stranger: FactoryBot.create(:account)
    }
    event = Event.find(@event.id)

    admins.each do |route, account|
      assert Event.admin?(event, account), "Expected #{route} to be an event admin"
      assert_includes Event.administered_by(account).pluck(:id), event.id, "Expected administered_by to include the event for #{route}"
      assert_equal Event.admin?(other_event, account).present?, Event.administered_by(account).pluck(:id).include?(other_event.id), "administered_by disagrees with admin? on another event for #{route}"
    end
    non_admins.each do |route, account|
      refute Event.admin?(event, account), "Expected #{route} not to be an event admin"
      refute_includes Event.administered_by(account).pluck(:id), event.id, "Expected administered_by to exclude the event for #{route}"
    end
    assert_empty Event.administered_by(nil).to_a
  end
end
