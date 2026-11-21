require_relative '../test_config'

class AccountSignOutTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  test 'signing out from the account menu' do
    covers_route 'POST /accounts/sign_out'
    account = FactoryBot.create(:account)
    sign_in account
    visit '/accounts/edit'
    find('.navbar a[data-bs-toggle="dropdown"]', text: account.name).click
    click_on 'Sign out'
    assert page.has_link?('Sign in')
    visit '/accounts/edit'
    assert page.has_current_path?('/accounts/new', ignore_query: true)
  end

  test 'a link to the old sign out URL asks, and its button signs out' do
    covers_route 'GET /accounts/sign_out'
    account = FactoryBot.create(:account)
    sign_in account
    visit '/accounts/sign_out'
    assert page.has_content?('Sign out of Dandelion in this browser?')
    click_on 'Sign out'
    assert page.has_link?('Sign in')
    visit '/accounts/edit'
    assert page.has_current_path?('/accounts/new', ignore_query: true)
  end

  # An <img src="/accounts/sign_out"> in an event's description would otherwise sign out everyone who saw it
  test 'a GET of the sign out URL leaves the session signed in' do
    account = FactoryBot.create(:account)
    sign_in_with_rack(account)
    get '/accounts/edit'
    assert_equal 200, last_response.status

    get '/accounts/sign_out'
    assert_equal 200, last_response.status
    get '/accounts/edit'
    assert_equal 200, last_response.status

    post '/accounts/sign_out'
    get '/accounts/edit'
    assert last_response.redirect?
  end
end
