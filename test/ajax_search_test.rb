require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class AjaxSearchTest < ActiveSupport::TestCase
  include Rack::Test::Methods

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
end
