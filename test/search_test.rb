require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class SearchTest < ActiveSupport::TestCase
  include Capybara::DSL

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
end
