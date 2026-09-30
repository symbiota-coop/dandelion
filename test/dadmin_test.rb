require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DadminTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def sign_in_as_admin
    admin = FactoryBot.create(:account, admin: true)
    sign_in_with_rack(admin)
    admin
  end

  def result_ids(path, params = {})
    get path, params
    assert last_response.ok?, "#{path} returned #{last_response.status}"
    JSON.parse(last_response.body)['results'].map { |result| result['id'] }
  end

  test 'signed-out visitors are sent to sign in' do
    get '/dadmin'
    assert last_response.redirect?
    assert_match %r{/accounts/sign_in\z}, last_response.location
  end

  test 'non-admins are kept out' do
    sign_in_with_rack(FactoryBot.create(:account))
    get '/dadmin/index/Account'
    assert last_response.redirect?
    refute_match %r{/dadmin}, last_response.location
  end

  test 'the home page lists every model' do
    sign_in_as_admin
    get '/dadmin'
    assert last_response.ok?
    assert_includes last_response.body, 'Ticket types'
    assert_includes last_response.body, '/dadmin/index/EventTag'
  end

  test 'an unknown model redirects to the admin home' do
    sign_in_as_admin
    get '/dadmin/index/Nope'
    assert last_response.redirect?
    assert_match %r{/dadmin\z}, last_response.location
  end

  test 'the list shows records with links to edit them and their lookups' do
    sign_in_as_admin
    create_event(name: 'Lookup Event')
    ticket_type = FactoryBot.create(:ticket_type, event: @event, name: 'Listed Ticket')
    get '/dadmin/index/TicketType'
    assert last_response.ok?
    assert_includes last_response.body, 'Listed Ticket'
    assert_includes last_response.body, "/dadmin/edit/TicketType/#{ticket_type.id}"
    assert_includes last_response.body, "/dadmin/edit/Event/#{@event.id}"
  end

  test 'text search matches text fields and lookups' do
    sign_in_as_admin
    create_event(name: 'Zebra Party')
    zebra = FactoryBot.create(:ticket_type, event: @event, name: 'Early bird')
    other = FactoryBot.create(:ticket_type, event: FactoryBot.create(:event, organisation: @organisation, name: 'Other'), name: 'Late')

    assert_equal [zebra.id.to_s], result_ids('/dadmin/index/TicketType.json', q: 'early')
    ids = result_ids('/dadmin/index/Event.json', q: 'zebra')
    assert_equal [@event.id.to_s], ids
    refute_includes result_ids('/dadmin/index/TicketType.json', q: 'early'), other.id.to_s
  end

  test 'criteria filter by text, number, checkbox and lookup, combined with all or any' do
    sign_in_as_admin
    create_event
    small = FactoryBot.create(:ticket_type, event: @event, name: 'Small', quantity: 5)
    large = FactoryBot.create(:ticket_type, event: @event, name: 'Large', quantity: 50, hidden: true)
    elsewhere = FactoryBot.create(:ticket_type, event: FactoryBot.create(:event, organisation: @organisation), name: 'Elsewhere', quantity: 5)

    criteria = ->(*rows, all_any: 'all') { { 'qk' => rows.map(&:first), 'qb' => rows.map { |row| row[1] }, 'qv' => rows.map(&:last), 'all_any' => all_any } }
    ids = ->(*rows, **opts) { result_ids('/dadmin/index/TicketType.json', criteria.(*rows, **opts)).sort }

    assert_equal [small.id.to_s], ids.(%w[name in small])
    assert_equal [large, elsewhere].map { |t| t.id.to_s }.sort, ids.(%w[name nin small])
    assert_equal [large.id.to_s], ids.(%w[quantity gte 10])
    assert_equal [large.id.to_s], ids.(%w[hidden in true])
    assert_equal [small, large].map { |t| t.id.to_s }.sort, ids.(['event_id', 'in', @event.id.to_s])
    assert_equal [small.id.to_s], ids.(%w[name in small], %w[quantity lt 10])
    assert_equal [small, large].map { |t| t.id.to_s }.sort, ids.(%w[name in small], %w[quantity gte 10], all_any: 'any')
  end

  test 'criteria can search a has-many collection' do
    sign_in_as_admin
    create_event(as: :with_vip)
    FactoryBot.create(:ticket_type, event: @with_vip, name: 'VIP')
    create_event(as: :without_vip)
    FactoryBot.create(:ticket_type, event: @without_vip, name: 'Standard')

    ids = result_ids('/dadmin/index/Event.json', 'qk' => ['ticket_types.name'], 'qb' => ['in'], 'qv' => ['vip'], 'all_any' => 'all')
    assert_equal [@with_vip.id.to_s], ids
  end

  test 'unsupported criteria are ignored rather than erroring' do
    sign_in_as_admin
    create_event
    FactoryBot.create(:ticket_type, event: @event)
    ids = result_ids('/dadmin/index/TicketType.json', 'qk' => %w[name], 'qb' => %w[gt], 'qv' => %w[x], 'all_any' => 'all')
    assert_equal 1, ids.length
  end

  test 'the list exports as CSV with lookups labelled' do
    sign_in_as_admin
    create_event
    FactoryBot.create(:ticket_type, event: @event, name: 'Exported')
    get '/dadmin/index/TicketType.csv'
    assert last_response.ok?
    rows = CSV.parse(last_response.body)
    assert_includes rows.first, 'name'
    assert_includes rows.first, 'event_id'
    exported = rows.find { |row| row.include?('Exported') }
    assert exported.any? { |cell| cell.to_s.include?("(id:#{@event.id})") }
  end

  test 'new records can have lookups prefilled from the URL' do
    sign_in_as_admin
    create_event
    get "/dadmin/new/TicketType?event_id=#{@event.id}"
    assert last_response.ok?
    assert_match(/name="ticket_type\[event_id\]".*?<option value="#{@event.id}" selected="selected">/m, last_response.body)
  end

  test 'records can be created, edited and deleted' do
    sign_in_as_admin
    post '/dadmin/new/EventTag', event_tag: { name: 'dadmin-tag' }
    tag = EventTag.find_by(name: 'dadmin-tag')
    assert tag
    assert last_response.redirect?

    post "/dadmin/edit/EventTag/#{tag.id}", event_tag: { name: 'dadmin-tag-renamed' }
    assert_equal 'dadmin-tag-renamed', tag.reload.name

    post "/dadmin/destroy/EventTag/#{tag.id}"
    assert_nil EventTag.find(tag.id)
  end

  test 'saving in a popup reloads the page that opened it' do
    sign_in_as_admin
    post '/dadmin/new/EventTag', event_tag: { name: 'popup-tag' }, popup: true
    assert last_response.ok?
    assert_includes last_response.body, 'window.opener.location.reload'
  end

  test 'a javascript: URL in a record is shown as text, not linked' do
    sign_in_as_admin
    create_event(facebook_event_url: 'javascript:alert(1)')
    create_event(as: :linked, facebook_event_url: 'https://example.com/event')
    get '/dadmin/index/Event'
    refute_includes last_response.body, 'href="javascript:alert(1)"'
    assert_includes last_response.body, 'href="https://example.com/event"'
  end

  test "editing an event doesn't load it into the layout" do
    sign_in_as_admin
    create_event
    get "/dadmin/edit/Event/#{@event.id}"
    assert last_response.ok?
    refute_includes last_response.body, 'application/ld+json'
  end
end
