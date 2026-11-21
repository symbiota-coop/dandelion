require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# A route's access: option (lib/route_access.rb), which says who may use it and is checked before the route's body runs
class RouteAccessTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  test 'access: :signed_in sends someone signed out to sign up, and lets them in once signed in' do
    covers_route 'GET /referrals'
    get '/referrals'
    assert last_response.redirect?
    assert_equal '/accounts/new', URI(last_response.location).path
    follow_redirect!
    assert_includes last_response.body, 'Please sign up or sign in to continue'

    sign_in_with_rack(FactoryBot.create(:account))
    get '/referrals'
    assert_equal 200, last_response.status
  end

  test "access: is checked after the app's before filter, so a sign in code in the link signs in first" do
    covers_route 'GET /referrals'
    account = FactoryBot.create(:account)
    get '/referrals', sign_in_code: account.issue_sign_in_code!
    follow_redirect! while last_response.redirect?
    assert_equal '/referrals', last_request.path
    assert_equal 200, last_response.status
  end

  test 'access: :admin refuses anyone but site admins before the route finds anything' do
    covers_route 'POST /e/:slug/do_hide_from_homepage'
    create_event
    sign_in_with_rack(FactoryBot.create(:account))
    post "/e/#{@event.slug}/do_hide_from_homepage"
    assert last_response.redirect?
    assert_equal '/', URI(last_response.location).path
    assert_equal false, @event.reload.hidden_from_homepage
    # Refused rather than a 404, so it doesn't say whether there's an event there
    post '/e/no-such-event/do_hide_from_homepage'
    assert last_response.redirect?

    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    post "/e/#{@event.slug}/do_hide_from_homepage"
    assert_equal 200, last_response.status
    assert_equal true, @event.reload.hidden_from_homepage
  end

  test "a level access: doesn't know fails as the route is defined" do
    error = assert_raises(ArgumentError) { Object.new.extend(RouteAccess).access(:everyone) }
    assert_includes error.message, ':public'
  end
end
