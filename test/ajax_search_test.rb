require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'rack/test'

class AjaxSearchTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def app
    Padrino.application
  end

  # No-op since we're using Rack::Test, not Capybara
  def save_screenshot(*); end

  def ajax_search(term = nil, type = nil)
    params = {}
    params[:term] = term if term
    params[:type] = type if type

    header 'X-Requested-With', 'XMLHttpRequest'
    get '/search', params
    last_response.body
  end

  test 'ajax search returns json for events' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, name: 'Test Event Search', prices: [0])

    json_response = JSON.parse(ajax_search('Test', 'events'))
    assert json_response.is_a?(Array)
    assert(json_response.any? { |r| r['value'].include?('Test Event Search') })
  end

  test 'ajax search returns json for accounts' do
    @account = FactoryBot.create(:account, name: 'Test Account Search', has_signed_in: true)

    json_response = JSON.parse(ajax_search('Test', 'accounts'))
    assert json_response.is_a?(Array)
    assert(json_response.any? { |r| r['value'].include?('Test Account Search') })
  end

  test 'ajax search returns json for organisations' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account, name: 'Test Organisation Search')

    json_response = JSON.parse(ajax_search('Test', 'organisations'))
    assert json_response.is_a?(Array)
    assert(json_response.any? { |r| r['value'].include?('Test Organisation Search') })
  end

  test 'ajax search returns json for gatherings' do
    @account = FactoryBot.create(:account)
    @gathering = FactoryBot.create(:gathering, account: @account, name: 'Test Gathering Search', listed: true, privacy: 'public')

    json_response = JSON.parse(ajax_search('Test', 'gatherings'))
    assert json_response.is_a?(Array)
    assert(json_response.any? { |r| r['value'].include?('Test Gathering Search') })
  end

  test 'ajax search returns all types when no type specified' do
    @account = FactoryBot.create(:account, name: 'Test Account', has_signed_in: true)
    @organisation = FactoryBot.create(:organisation, account: @account, name: 'Test Organisation')
    @gathering = FactoryBot.create(:gathering, account: @account, name: 'Test Gathering', listed: true, privacy: 'public')
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, name: 'Test Event', prices: [0])

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
    @account = FactoryBot.create(:account, name: 'ABC Test User', has_signed_in: true)
    json_response = JSON.parse(ajax_search('ABC', 'accounts'))
    assert(json_response.any? { |r| r['value'].include?('ABC Test User') })
  end

  test 'ajax search rejects queries longer than 200 characters' do
    assert ajax_search('a' * 201).empty?
    # Verify boundary: 200 characters should work
    @account = FactoryBot.create(:account, name: 'Boundary Test Account', has_signed_in: true)
    json_response = JSON.parse(ajax_search('Boundary' + ('x' * 192), 'accounts'))
    assert json_response.is_a?(Array)
  end

  test 'ajax search handles nil query' do
    assert ajax_search.empty?
  end
end
