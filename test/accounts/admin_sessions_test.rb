require_relative '../test_config'
require_relative '../helpers/sign_in_helpers'

# Site admins' sessions: the admin pages need a session that wasn't started only from an emailed link, which anyone the
# email is forwarded to can open
class AccountAdminSessionsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include SignInHelpers

  XHR = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }.freeze

  def create_site_admin
    FactoryBot.create(:account, admin: true).tap do |admin|
      admin.set(email_confirmed: true)
      admin.generate_link_token!
    end
  end

  test 'a site admin signed in from an emailed link is sent a sign in code, and has the admin pages once they enter it' do
    covers_route 'GET /stats/charts', 'POST /e/:slug/do_hide_from_homepage'
    admin = create_site_admin
    create_event
    get '/', link_token: admin.link_token
    get '/accounts/edit'
    assert last_response.ok?, 'The link signs the admin in'

    post "/e/#{@event.slug}/do_hide_from_homepage", {}, 'HTTP_REFERER' => "http://example.org/e/#{@event.slug}"
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    assert_equal false, @event.reload.hidden_from_homepage
    get '/stats/charts', {}, XHR
    assert_equal 403, last_response.status

    email = recorded_email { get '/stats/charts' }
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    assert_equal({ 'account_id' => admin.id.to_s }, Rack::Utils.parse_query(URI(last_response.location).query))
    assert_equal [admin.email], email.recipients
    assert_equal 'Sign in code for Dandelion', email.subject_line
    follow_redirect!
    assert_includes last_response.body, 'Enter it to use the admin pages.'

    get '/', sign_in_code: email.variables[admin.email]['token']
    assert_equal '/stats/charts', URI(last_response.location).path
    follow_redirect!
    assert last_response.ok?
    post "/e/#{@event.slug}/do_hide_from_homepage"
    assert_equal 200, last_response.status
    assert_equal true, @event.reload.hidden_from_homepage
  end

  test "someone who isn't a site admin is still refused the admin pages, however they signed in" do
    covers_route 'GET /stats/charts'
    account = FactoryBot.create(:account)
    account.generate_link_token!
    get '/', link_token: account.link_token
    get '/stats/charts'
    assert_redirected_to '/'

    sign_in_with_rack(account)
    get '/stats/charts'
    assert_redirected_to '/'
  end

  test 'a site admin signed in with a password or a sign in code goes straight to the admin pages' do
    covers_route 'GET /stats/charts'
    admin = create_site_admin
    sign_in_with_password_via_rack(admin)
    get '/stats/charts'
    assert last_response.ok?

    sign_in_with_rack(admin)
    get '/stats/charts'
    assert last_response.ok?
  end

  test 'a site admin who opened an emailed link enters the sign in code they are sent, and is taken back to the admin page' do
    covers_route 'GET /stats/charts'
    admin = create_site_admin
    visit "/?link_token=#{admin.link_token}"
    assert page.has_content?('Signed in via a link')

    visit '/stats/charts'
    assert page.has_content?("We've emailed you a sign in code to confirm it's you. Enter it to use the admin pages.")
    enter_sign_in_code(admin)
    assert page.has_current_path?('/stats/charts')
    visit '/stats/charts'
    assert page.has_current_path?('/stats/charts')
  end
end
