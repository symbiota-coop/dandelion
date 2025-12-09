require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DandelionTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'search page loads' do
    visit '/search'
    assert page.has_selector?('form#search-form')
    assert page.has_selector?('ul.search-tab')
    assert page.has_selector?('input[name="q"]')
  end

  test 'full page search for events' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, name: 'Full Page Event Search', prices: [0])

    visit '/search?q=Full&type=events'
    assert page.has_selector?('ul.search-tab li.active', text: 'Events')
    assert page.has_content?('Full Page Event Search')
  end

  test 'full page search for accounts' do
    @account = FactoryBot.create(:account, name: 'Full Page Account Search', has_signed_in: true)

    visit '/search?q=Full&type=accounts'
    assert page.has_selector?('ul.search-tab li.active', text: 'People')
    assert page.has_content?('Full Page Account Search')
  end

  test 'full page search for organisations' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account, name: 'Full Page Organisation Search')

    visit '/search?q=Full&type=organisations'
    assert page.has_selector?('ul.search-tab li.active', text: 'Organisations')
    assert page.has_content?('Full Page Organisation Search')
  end

  test 'full page search for gatherings' do
    @account = FactoryBot.create(:account)
    @gathering = FactoryBot.create(:gathering, account: @account, name: 'Full Page Gathering Search', listed: true, privacy: 'public')

    visit '/search?q=Full&type=gatherings'
    assert page.has_selector?('ul.search-tab li.active', text: 'Gatherings')
    assert page.has_content?('Full Page Gathering Search')
  end

  test 'full page search defaults to events type' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, name: 'Default Event Search', prices: [0])

    visit '/search?q=Default'
    assert page.has_selector?('ul.search-tab li.active', text: 'Events')
    assert page.has_content?('Default Event Search')
  end

  test 'search with event prefix redirects to event page when exact match' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, name: 'Exact Match Event', prices: [0])

    visit '/search?q=event:"Exact Match Event"'
    assert_equal "/e/#{@event.slug}", page.current_path
  end

  test 'search with account prefix redirects to account page when exact match' do
    @account = FactoryBot.create(:account, name: 'Exact Match Account', has_signed_in: true)

    visit '/search?q=account:"Exact Match Account"'
    assert_equal "/u/#{@account.username}", page.current_path
  end

  test 'search with organisation prefix redirects to organisation page when exact match' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account, name: 'Exact Match Organisation')

    visit '/search?q=organisation:"Exact Match Organisation"'
    assert_equal "/o/#{@organisation.slug}", page.current_path
  end

  test 'search with gathering prefix redirects to gathering page when exact match' do
    @account = FactoryBot.create(:account)
    @gathering = FactoryBot.create(:gathering, account: @account, name: 'Exact Match Gathering', listed: true, privacy: 'public')

    visit '/search?q=gathering:"Exact Match Gathering"'
    assert_equal "/g/#{@gathering.slug}", page.current_path
  end

  test 'search parses query with prefix without quotes' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, name: 'Unquoted Event Search', prices: [0])

    visit '/search?q=event:Unquoted'
    # Should stay on search page (partial match doesn't redirect)
    assert_equal '/search', page.current_path
    assert page.has_selector?('ul.search-tab li.active', text: 'Events')
    assert page.has_content?('Unquoted Event Search')
  end

  test 'search handles empty query' do
    visit '/search?q='
    assert page.has_selector?('form#search-form')
    assert page.has_selector?('ul.search-tab')
  end
end
