require_relative '../test_config'
require_relative '../helpers/sign_in_helpers'

# Signing in with a code, a link or a password, and sessions
class AccountSignInsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include SignInHelpers

  test 'sign in token does not replace an existing session' do
    victim = FactoryBot.create(:account)
    attacker = FactoryBot.create(:account)
    sign_in_with_rack(victim)
    attacker.generate_link_token!
    token = attacker.link_token

    get '/', link_token: token
    follow_redirect! while last_response.redirect?

    assert_equal victim.id.to_s, last_request.session[:account_id]
    assert_equal token, attacker.reload.link_token
    assert_equal 0, attacker.sign_ins.count
  end

  test 'sign in token works when session account_id is stale' do
    stale_id = FactoryBot.create(:account).id
    buyer = FactoryBot.create(:account)
    sign_in_with_rack(Account.find(stale_id))
    Account.find(stale_id).delete
    buyer.generate_link_token!

    get '/', link_token: buyer.link_token
    follow_redirect! while last_response.redirect?

    assert_equal buyer.id.to_s, last_request.session[:account_id]
    assert_equal 1, buyer.reload.sign_ins.count
  end

  test 'a sign in code works once' do
    account = FactoryBot.create(:account)
    code = account.issue_sign_in_code!

    clear_cookies
    get '/', sign_in_code: code
    assert_equal account.id.to_s, last_request.session[:account_id]

    clear_cookies
    get '/', sign_in_code: code
    follow_redirect! while last_response.redirect?
    assert_nil last_request.session[:account_id]
    assert_includes last_response.body, "That sign in code isn't valid any longer"
  end

  test 'a GET sends the session cookie back only when it changes the session or is a page' do
    account = FactoryBot.create(:account)
    xhr = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
    sign_in_with_rack(account)

    # Sent back, these could arrive after a newer session and replace it
    get '/', {}, xhr
    assert last_response.ok?
    assert_nil last_response.headers['set-cookie']
    get '/stylesheets/app.css'
    assert last_response.ok?
    assert_nil last_response.headers['set-cookie']

    # Pages still send it back, renewing its expiry
    get '/'
    assert last_response.ok?
    assert last_response.headers['set-cookie']

    # A background request that signs in changes the session, so it's sent back
    other_account = FactoryBot.create(:account, email_confirmed: true)
    clear_cookies
    get '/', { sign_in_code: other_account.issue_sign_in_code! }, xhr
    assert_equal other_account.id.to_s, last_request.session[:account_id]
    assert last_response.headers['set-cookie']
  end

  test 'a POST from our own pages keeps the session, and a cross-site one runs signed out' do
    account = FactoryBot.create(:account)
    # Signed in, a ticket that isn't there is a 404; signed out, sign_in_required! sends you to sign up
    path = "/tickets/#{BSON::ObjectId.new}/toggle_resale"

    # A form on a page with Referrer-Policy: no-referrer, like an order page, posts with Origin: null
    sign_in_with_rack(account)
    post path, {}, { 'HTTP_ORIGIN' => 'null', 'HTTP_SEC_FETCH_SITE' => 'same-origin' }
    assert last_response.not_found?

    sign_in_with_rack(account)
    post path, {}, { 'HTTP_ORIGIN' => 'https://elsewhere.example', 'HTTP_SEC_FETCH_SITE' => 'cross-site' }
    assert last_response.redirect?
    assert_equal '/accounts/new', URI(last_response.location).path

    # Without Sec-Fetch-Site (an older browser), an Origin we can't match still drops the session
    sign_in_with_rack(account)
    post path, {}, { 'HTTP_ORIGIN' => 'null' }
    assert_equal '/accounts/new', URI(last_response.location).path
  end

  test 'asking for a sign in code again resends the code already sent' do
    account = FactoryBot.create(:account)
    code = account.issue_sign_in_code!

    visit '/accounts/sign_in'
    click_link 'Get a sign in code to your email'
    fill_in 'sign-in-code-email', with: account.email
    click_button 'Get code'
    assert page.has_content?("A sign in code was sent to #{account.email}")
    assert_equal code, account.reload.issue_sign_in_code!

    fill_in 'code', with: code
    click_button 'Submit'
    assert page.has_content?('Signed in with a sign in code')
  end

  test 'asking for a sign in code gives a new one once the last has little time left or was used' do
    account = FactoryBot.create(:account)
    code = account.issue_sign_in_code!
    account.set(sign_in_code_expires_at: 10.minutes.from_now)
    new_code = account.issue_sign_in_code!
    refute_equal code, new_code
    assert_nil Account.with_sign_in_code(code)

    assert account.redeem_sign_in_code!(new_code)
    refute_equal new_code, account.reload.issue_sign_in_code!
  end

  test 'revoking sessions keeps the API key and calendar feed key' do
    account = FactoryBot.create(:account)
    api_key = account.api_key
    ics_key = account.ensure_ics_key!

    account.revoke_sessions!
    account.reload
    assert_equal api_key, account.api_key
    assert_equal ics_key, account.ics_key
  end

  test 'links with the old sign_in_token param still sign in' do
    account = FactoryBot.create(:account)
    account.generate_link_token!
    clear_cookies
    get '/', sign_in_token: account.link_token
    assert_equal account.id.to_s, last_request.session[:account_id]
  end

  test 'a session from an email link cannot change the email or password without a code' do
    account = FactoryBot.create(:account)
    crypted_password = account.crypted_password
    account.generate_link_token!
    clear_cookies
    get '/', link_token: account.link_token

    post '/accounts/edit', account: { name: account.name, email: 'taken-over@example.com' }
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    get '/accounts/password'
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    post '/accounts/password', password: 'taken-over-password', password_confirmation: 'taken-over-password'
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    account.reload
    refute_equal 'taken-over@example.com', account.email
    assert_equal crypted_password, account.crypted_password
  end

  test 'the profile form no longer changes the password' do
    account = FactoryBot.create(:account)
    crypted_password = account.crypted_password
    sign_in_with_rack(account)
    post '/accounts/edit', account: { name: 'A New Name', email: account.email, password: 'a-new-password' }
    account.reload
    assert_equal 'A New Name', account.name
    assert_equal crypted_password, account.crypted_password
  end

  test 'changing the password needs the two passwords to match' do
    account = FactoryBot.create(:account)
    crypted_password = account.crypted_password
    sign_in(account)
    visit '/accounts/password'
    fill_in 'New password', with: 'a-new-password'
    fill_in 'Confirm new password', with: 'a-different-password'
    click_button 'Change password'
    assert page.has_content?("The passwords didn't match.")
    assert_equal crypted_password, account.reload.crypted_password
  end

  # The form's minlength stops a browser sending a short one
  test 'changing the password needs it to be long enough' do
    account = FactoryBot.create(:account)
    crypted_password = account.crypted_password
    sign_in_with_rack(account)
    post '/accounts/password', password: 'short', password_confirmation: 'short'
    assert_includes last_response.body, "Your password wasn't changed"
    assert_equal crypted_password, account.reload.crypted_password
  end

  test 'changing the email sends a confirmation email whose link still works' do
    account = FactoryBot.create(:account)
    sign_in(account)
    sent_tokens = []
    original = Account.instance_method(:send_confirmation_email)
    Account.define_method(:send_confirmation_email) { sent_tokens << link_token_for_email }

    visit '/accounts/edit'
    fill_in 'Email', with: 'new-address@example.com'
    click_button 'Save profile'
    assert page.has_content?('Please click the link in the email we sent to confirm your new email address')
    assert_equal 'new-address@example.com', account.reload.email
    refute account.email_confirmed?
    assert_equal [account.link_token], sent_tokens

    visit "/confirm_email/#{sent_tokens.first}"
    assert page.has_button?('Confirm my email address')
  ensure
    Account.define_method(:send_confirmation_email, original)
  end

  test 'a session from an email link can still edit the rest of the profile' do
    account = FactoryBot.create(:account)
    account.generate_link_token!
    visit "/?link_token=#{account.link_token}"

    visit '/accounts/edit'
    fill_in 'Full name', with: 'A New Name'
    click_button 'Save profile'
    assert page.has_content?('Your account was updated successfully')
    assert_equal 'A New Name', account.reload.name
  end

  test 'the API key tab shows the key only after a sign in code' do
    covers 'integrations/zapier-and-mcp-same-api-key@a1a235'
    account = FactoryBot.create(:account)
    account.set(email_confirmed: true)
    account.generate_link_token!
    clear_cookies
    get '/accounts/edit', link_token: account.link_token
    assert last_response.ok?
    refute_includes last_response.body, account.api_key

    get '/accounts/api_key'
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    get '/', sign_in_code: account.issue_sign_in_code!
    assert_equal '/accounts/api_key', URI(last_response.location).path
    follow_redirect!
    assert_includes last_response.body, account.api_key
    get '/accounts/edit'
    refute_includes last_response.body, account.api_key
  end

  test 'a session from an email link needs a sign in code to delete the account' do
    account = FactoryBot.create(:account)
    account.set(email_confirmed: true)
    account.generate_link_token!
    clear_cookies
    get '/accounts/edit', link_token: account.link_token
    assert last_response.ok?

    get '/accounts/delete'
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    post '/accounts/destroy', email: account.email
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    assert Account.find(account.id)
  end

  test 'deleting the account from a session from an email link, after entering a sign in code' do
    account = FactoryBot.create(:account)
    account.set(email_confirmed: true)
    account.generate_link_token!
    visit "/accounts/edit?link_token=#{account.link_token}"
    click_link 'Delete account'
    assert page.has_content?('To delete your account, enter the code below.')
    assert Account.find(account.id)

    enter_sign_in_code(account)
    assert page.has_current_path?('/accounts/delete')
    # Labelled by aria-label, which Capybara doesn't match by default
    fill_in 'email', with: account.email
    click_button 'Delete account'
    assert page.has_content?('Your account was deleted')
    assert_nil Account.find(account.id)
  end

  test 'a session from an email link needs a sign in code to disconnect a provider' do
    account = FactoryBot.create(:account)
    account.set(email_confirmed: true)
    account.provider_links.create!(provider: 'Google', provider_uid: 'google-uid-disconnect', omniauth_hash: { 'uid' => 'google-uid-disconnect' })
    account.generate_link_token!
    clear_cookies
    get '/accounts/edit', link_token: account.link_token
    assert last_response.ok?

    post '/accounts/disconnect/google_oauth2'
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    assert_equal ['Google'], account.reload.provider_links.map(&:provider)
  end

  test 'disconnecting a provider from a session from an email link, after entering a sign in code' do
    account = FactoryBot.create(:account)
    account.set(email_confirmed: true)
    account.provider_links.create!(provider: 'Google', provider_uid: 'google-uid-disconnect', omniauth_hash: { 'uid' => 'google-uid-disconnect' })
    account.generate_link_token!
    visit "/accounts/providers?link_token=#{account.link_token}"
    click_link 'Disconnect'
    assert page.has_content?('Nothing was disconnected: enter the code below, then disconnect it again.')
    assert_equal ['Google'], account.reload.provider_links.map(&:provider)

    enter_sign_in_code(account)
    assert page.has_current_path?('/accounts/providers')
    click_link 'Disconnect'
    assert page.has_content?('Disconnected!')
    assert page.has_current_path?('/accounts/providers')
    assert_empty account.reload.provider_links
  end

  test 'the API key tab replaces the API key and the calendar key separately' do
    account = FactoryBot.create(:account)
    api_key = account.api_key
    ics_key = account.ensure_ics_key!
    sign_in(account)
    visit '/accounts/api_key'
    assert page.has_field?('ics_key', with: ics_key)

    click_button_and_confirm 'Replace API key'
    assert page.has_content?('Your API key was replaced')
    account.reload
    refute_equal api_key, account.api_key
    assert_nil Account.find_by(api_key: api_key)
    assert_equal ics_key, account.ics_key
    assert page.has_field?('api_key', with: account.api_key)

    api_key = account.api_key
    click_button_and_confirm 'Replace calendar key'
    assert page.has_content?('Your calendar key was replaced')
    account.reload
    refute_equal ics_key, account.ics_key
    assert_nil Account.find_by(ics_key: ics_key)
    assert_equal api_key, account.api_key
    assert page.has_field?('ics_key', with: account.ics_key)
  end

  test 'changing the password signs out other sessions and ends the links already sent' do
    account = FactoryBot.create(:account)
    # Signs in first, as signing in resets every browser
    sign_in(account)
    account.generate_link_token!
    link = account.link_token
    Capybara.using_session(:other_browser) do
      visit "/?link_token=#{link}"
      visit '/accounts/edit'
      assert page.has_field?('Full name')
    end
    link = account.reload.link_token # signing in made a new one

    visit '/accounts/password'
    fill_in 'New password', with: 'a-new-password'
    fill_in 'Confirm new password', with: 'a-new-password'
    click_button 'Change password'
    assert page.has_content?('Your password was changed, and other browsers were signed out.')
    assert account.reload.password_matches?('a-new-password')
    visit '/accounts/edit'
    assert page.has_field?('Full name')

    Capybara.using_session(:other_browser) do
      visit '/accounts/edit'
      assert page.has_current_path?('/accounts/new', ignore_query: true)
      visit "/?link_token=#{link}"
      assert page.has_content?("That sign in link isn't valid any longer")
    end
  end

  test 'a session from an email link needs a code to sign out other browsers' do
    account = FactoryBot.create(:account)
    account.generate_link_token!
    clear_cookies
    get '/', link_token: account.link_token
    post '/accounts/sign_out_other_browsers'
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
  end

  test 'signing out of other browsers keeps this one' do
    account = FactoryBot.create(:account)
    sign_in(account)
    account.generate_link_token!
    Capybara.using_session(:other_browser) do
      visit "/?link_token=#{account.link_token}"
      visit '/accounts/edit'
      assert page.has_field?('Full name')
    end

    visit '/accounts/password'
    click_button_and_confirm 'Sign out other browsers', button: 'Sign me out of other browsers'
    assert page.has_content?('Your other browsers were signed out.')
    visit '/accounts/edit'
    assert page.has_field?('Full name')
    Capybara.using_session(:other_browser) do
      visit '/accounts/edit'
      assert page.has_current_path?('/accounts/new', ignore_query: true)
    end
  end

  test 'a session from before session tokens is kept until the account revokes its sessions' do
    account = FactoryBot.create(:account)
    clear_cookies
    env 'rack.session', { 'account_id' => account.id.to_s }
    get '/accounts/edit'
    assert last_response.ok?
    assert_equal account.reload.session_token, last_request.session[:session_token]

    account.revoke_sessions!
    clear_cookies
    env 'rack.session', { 'account_id' => account.id.to_s }
    get '/accounts/edit'
    assert last_response.redirect?
    assert_nil last_request.session[:account_id]
  end

  test 'a session from before session tokens is not given the token of a revocation at the same moment' do
    account = FactoryBot.create(:account)
    clear_cookies
    env 'rack.session', { 'account_id' => account.id.to_s }
    original = Account.instance_method(:session_token!)
    # The revocation lands after the request has read the account, before it gives the session a token
    Account.define_method(:session_token!) do
      Account.find(id).revoke_sessions!
      original.bind_call(self)
    end
    get '/accounts/edit'
    assert last_response.redirect?
    assert_nil last_request.session[:account_id]
  ensure
    Account.define_method(:session_token!, original)
  end
end
