require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class SearchTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  class CapturingCollection
    attr_reader :pipelines

    def initialize
      @pipelines = []
    end

    def aggregate(pipeline, **_kwargs)
      @pipelines << pipeline
      []
    end
  end

  def ajax_search(term = nil, type = nil)
    params = {}
    params[:term] = term if term
    params[:type] = type if type

    header 'X-Requested-With', 'XMLHttpRequest'
    get '/search', params
    last_response.body
  end

  def assert_ajax_includes(term, type, value)
    json_response = JSON.parse(ajax_search(term, type))
    assert json_response.is_a?(Array)
    assert(json_response.any? { |r| r['value'].include?(value) })
  end

  def search_filter_for(pipeline)
    pipeline.first.fetch(:$search).fetch(:compound).fetch(:filter)
  end

  def suffix_match_for(pipeline)
    pipeline.find { |stage| stage.key?(:$match) }.fetch(:$match)
  end

  def equals_filters(node)
    case node
    when Array
      node.flat_map { |item| equals_filters(item) }
    when Hash
      if node[:equals]
        [[node[:equals][:path], node[:equals][:value]]]
      elsif node[:compound]
        equals_filters(node[:compound][:filter]) + equals_filters(node[:compound][:should])
      else
        []
      end
    else
      []
    end
  end

  def range_filters(node)
    case node
    when Array
      node.flat_map { |item| range_filters(item) }
    when Hash
      if node[:range]
        node[:range].except(:path).map { |operator, value| [node[:range][:path], operator, value] }
      elsif node[:compound]
        range_filters(node[:compound][:filter]) + range_filters(node[:compound][:should])
      else
        []
      end
    else
      []
    end
  end

  def stringify_keys(hash)
    hash.transform_keys(&:to_s)
  end

  test 'full page search for events' do
    create_event(name: 'Full Page Event Search', prices: [0])

    visit '/search?q=Full&type=events'
    assert page.has_selector?('ul.search-tab li.active', text: 'Events')
    assert page.has_content?('Full Page Event Search')
  end

  test 'full page search for accounts' do
    FactoryBot.create(:account, name: 'Full Page Account Search', has_signed_in: true)

    visit '/search?q=Full&type=accounts'
    assert page.has_selector?('ul.search-tab li.active', text: 'People')
    assert page.has_content?('Full Page Account Search')
  end

  test 'full page search for organisations' do
    create_organisation(name: 'Full Page Organisation Search')

    visit '/search?q=Full&type=organisations'
    assert page.has_selector?('ul.search-tab li.active', text: 'Organisations')
    assert page.has_content?('Full Page Organisation Search')
  end

  test 'full page search for gatherings' do
    create_gathering(:public, name: 'Full Page Gathering Search')

    visit '/search?q=Full&type=gatherings'
    assert page.has_selector?('ul.search-tab li.active', text: 'Gatherings')
    assert page.has_content?('Full Page Gathering Search')
  end

  test 'search with event prefix redirects to event page when exact match' do
    create_event(name: 'Exact Match Event', prices: [0])

    visit '/search?q=event:"Exact Match Event"'
    assert_equal "/e/#{@event.slug}", page.current_path
  end

  test 'search with account prefix redirects to account page when exact match' do
    account = FactoryBot.create(:account, name: 'Exact Match Account', has_signed_in: true)

    visit '/search?q=account:"Exact Match Account"'
    assert_equal "/u/#{account.username}", page.current_path
  end

  test 'search with organisation prefix redirects to organisation page when exact match' do
    create_organisation(name: 'Exact Match Organisation')

    visit '/search?q=organisation:"Exact Match Organisation"'
    assert_equal "/o/#{@organisation.slug}", page.current_path
  end

  test 'search with gathering prefix redirects to gathering page when exact match' do
    create_gathering(:public, name: 'Exact Match Gathering')

    visit '/search?q=gathering:"Exact Match Gathering"'
    assert_equal "/g/#{@gathering.slug}", page.current_path
  end

  test 'search parses query with prefix without quotes' do
    create_event(name: 'Unquoted Event Search', prices: [0])

    visit '/search?q=event:Unquoted'
    # Should stay on search page (partial match doesn't redirect)
    assert_equal '/search', page.current_path
    assert page.has_selector?('ul.search-tab li.active', text: 'Events')
    assert page.has_content?('Unquoted Event Search')
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Ajax search
  # ═══════════════════════════════════════════════════════════════════════════

  test 'ajax search returns json for events' do
    create_event(name: 'Test Event Search', prices: [0])
    assert_ajax_includes('Test', 'events', 'Test Event Search')
  end

  test 'ajax search returns json for accounts' do
    FactoryBot.create(:account, name: 'Test Account Search', has_signed_in: true)
    assert_ajax_includes('Test', 'accounts', 'Test Account Search')
  end

  test 'ajax search returns json for organisations' do
    create_organisation(name: 'Test Organisation Search')
    assert_ajax_includes('Test', 'organisations', 'Test Organisation Search')
  end

  test 'ajax search returns json for gatherings' do
    create_gathering(:public, name: 'Test Gathering Search')
    assert_ajax_includes('Test', 'gatherings', 'Test Gathering Search')
  end

  test 'ajax search returns all types when no type specified' do
    FactoryBot.create(:account, name: 'Test Account', has_signed_in: true)
    create_organisation(name: 'Test Organisation')
    create_gathering(:public, name: 'Test Gathering')
    create_event(name: 'Test Event', prices: [0])

    json_response = JSON.parse(ajax_search('Test'))
    assert json_response.is_a?(Array)
    assert(json_response.any? { |r| r['value'].include?('Test Event') })
    assert(json_response.any? { |r| r['value'].include?('Test Account') })
    assert(json_response.any? { |r| r['value'].include?('Test Organisation') })
    assert(json_response.any? { |r| r['value'].include?('Test Gathering') })
  end

  test 'ajax search rejects queries shorter than 3 characters' do
    assert ajax_search('ab').empty?
    # Verify boundary: 3 characters should work
    FactoryBot.create(:account, name: 'ABC Test User', has_signed_in: true)
    assert_ajax_includes('ABC', 'accounts', 'ABC Test User')
  end

  test 'ajax search rejects queries longer than 200 characters' do
    assert ajax_search('a' * 201).empty?
    # Verify boundary: 200 characters should work
    FactoryBot.create(:account, name: 'Boundary Test Account', has_signed_in: true)
    json_response = JSON.parse(ajax_search('Boundary' + ('x' * 192), 'accounts'))
    assert json_response.is_a?(Array)
  end

  test 'ajax search returns plain text labels without html' do
    xss_name = '<img src=x onerror=alert(1)> XSS Account'
    account = FactoryBot.create(:account, name: 'XSS Account', has_signed_in: true)
    account.set(name: xss_name)

    result = JSON.parse(ajax_search('XSS', 'accounts')).find { |r| r['value'].include?('XSS Account') }
    assert result
    assert_equal xss_name, result['label']
    assert_equal 'bi-person-fill', result['icon']
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Atlas search filter translation
  # ═══════════════════════════════════════════════════════════════════════════

  test 'pushes supported organisation event filters into atlas search' do
    collection = CapturingCollection.new
    organisation_id = BSON::ObjectId.new
    from = Time.utc(2026, 7, 4, 23)
    scope = Event.unscoped
                 .or({ organisation_id: organisation_id }, { cohosts_ids_cache: organisation_id })
                 .and(deleted_at: nil)
                 .and(secret: false)
                 .future_current_evergreen(from)

    Event.stub(:collection, collection) do
      Event.search('Sound', scope, regex_search: false)
    end

    filter = search_filter_for(collection.pipelines.first)
    suffix_match = suffix_match_for(collection.pipelines.first)

    assert_includes equals_filters(filter), ['organisation_id', organisation_id]
    assert_includes equals_filters(filter), ['cohosts_ids_cache', organisation_id]
    assert_includes equals_filters(filter), ['secret', false]
    assert_includes range_filters(filter), ['start_time', :gte, from]
    assert_includes range_filters(filter), ['end_time', :gte, from]
    assert_includes equals_filters(filter), ['show_after_start_time', true]
    assert_includes equals_filters(filter), ['evergreen', true]

    refute suffix_match.keys.map(&:to_s).include?('$or')
    assert_equal({ 'deleted_at' => nil }, stringify_keys(suffix_match))
  end

  test 'leaves unsupported or branch in post search match' do
    collection = CapturingCollection.new
    organisation_id = BSON::ObjectId.new
    scope = Event.unscoped.or({ organisation_id: organisation_id }, { deleted_at: nil })

    Event.stub(:collection, collection) do
      Event.search('Sound', scope, regex_search: false)
    end

    filter = search_filter_for(collection.pipelines.first)
    suffix_match = suffix_match_for(collection.pipelines.first)

    refute_includes equals_filters(filter), ['organisation_id', organisation_id]
    assert suffix_match.keys.map(&:to_s).include?('$or')
  end
end
