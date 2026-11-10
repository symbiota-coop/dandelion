require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# Signing in, with a code, a link, a password, Google, Ethereum or Bluesky; sessions; connecting providers; and confirming the email
class AccountSignInsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  ATPROTO_ALICE = 'did:plc:alice'.freeze

  ATPROTO_ALICE_PDS = 'https://pds.alice.test'.freeze

  ATPROTO_ALICE_AS = 'https://as.alice.test'.freeze

  ATPROTO_MALLORY = 'did:plc:mallory'.freeze

  ATPROTO_MALLORY_PDS = 'https://pds.mallory.test'.freeze

  ATPROTO_MALLORY_AS = 'https://as.mallory.test'.freeze

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

  test 'email confirmation link confirms the address with its button' do
    account = FactoryBot.create(:account, email_confirmed: false)
    account.generate_link_token!

    visit "/confirm_email/#{account.link_token}"
    # Signed in as the account, whose email the page asks about
    assert page.has_content?("Confirm that #{account.email} is your email address?")
    refute account.reload.email_confirmed

    click_button 'Confirm my email address'
    assert page.has_content?('Your email address was confirmed')
    assert account.reload.email_confirmed
  end

  test 'email confirmation link confirms an already signed-in account' do
    account = FactoryBot.create(:account, email_confirmed: false)
    sign_in(account)
    account.set(email_confirmed: false)

    visit "/confirm_email/#{account.reload.link_token}"
    click_button 'Confirm my email address'

    assert page.has_content?('Your email address was confirmed')
    assert account.reload.email_confirmed
  end

  test 'the confirmation button does nothing without the link' do
    account = FactoryBot.create(:account)
    sign_in_via_rack(account)

    post '/accounts/confirm_email'
    follow_redirect! while last_response.redirect?
    refute account.reload.email_confirmed
    assert_includes last_response.body, "That confirmation link isn't valid"
  end

  test 'email confirmation link rejects a token that does not match the signed-in account' do
    account = FactoryBot.create(:account, email_confirmed: false)
    sign_in_with_rack(account)
    account.set(email_confirmed: false)

    get '/confirm_email/not-a-real-token'
    follow_redirect! while last_response.redirect?

    refute account.reload.email_confirmed
    assert_includes last_response.body, "That confirmation link isn't valid"
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

  test 'connecting a provider while signed in waits for confirmation' do
    account = FactoryBot.create(:account)
    sign_in(account)
    visit_omniauth_as(uid: 'google-uid-connect')
    assert page.has_content?('Connect the Google account')
    assert_empty account.reload.provider_links

    click_button 'Connect'
    assert page.has_content?('Connected!')
    assert_equal ['google-uid-connect'], account.reload.provider_links.map(&:provider_uid)
  end

  test 'cancelling a provider connection links nothing' do
    account = FactoryBot.create(:account)
    sign_in(account)
    visit_omniauth_as(uid: 'google-uid-cancel')
    click_button 'Cancel'
    assert page.has_current_path?('/accounts/providers')
    assert page.has_link?('Connect', href: '/auth/google_oauth2')
    assert_empty account.reload.provider_links
  end

  test 'confirming a provider connection after cancelling it links nothing' do
    account = FactoryBot.create(:account)
    sign_in_with_rack(account)
    omniauth_callback_as(uid: 'google-uid-cancel')
    post '/accounts/providers/cancel'
    post '/accounts/providers/confirm'
    assert_empty account.reload.provider_links
  end

  test 'connecting a provider asks a session that signed in with a password for a sign in code' do
    account = FactoryBot.create(:account)
    visit '/accounts/sign_in'
    fill_in 'Email', with: account.email
    fill_in 'Password', with: account.password
    click_button 'Sign in'
    assert page.has_content?('Signed in')

    visit_omniauth_as(uid: 'google-uid-unverified')
    assert page.has_content?('To connect Google, enter the code below, then connect it again.')
    enter_sign_in_code(account)
    assert page.has_current_path?('/accounts/providers')
    assert_empty account.reload.provider_links

    visit_omniauth_as(uid: 'google-uid-unverified')
    click_button 'Connect'
    assert page.has_content?('Connected!')
    assert_equal ['google-uid-unverified'], account.reload.provider_links.map(&:provider_uid)
  end

  test 'connecting a provider needs a sign in code from the last hour' do
    account = FactoryBot.create(:account)
    sign_in_via_rack(account)
    omniauth_callback_as(uid: 'google-uid-unverified')
    assert_equal '/accounts/sign_in_code', last_request.path
    post '/accounts/providers/confirm'
    assert_empty account.reload.provider_links
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

  test 'the notification settings form cannot change the email' do
    account = FactoryBot.create(:account)
    account.generate_link_token!
    clear_cookies
    get '/', link_token: account.link_token

    post '/accounts/subscriptions', account: { email: 'taken-over@example.com', unsubscribed_messages: '1' }
    account.reload
    refute_equal 'taken-over@example.com', account.email
    assert account.unsubscribed_messages
  end

  test 'opening the confirmation link, as a mail scanner does, neither confirms the email, signs anyone out nor uses up the link' do
    start_omniauth_signup(email: 'scanned@example.com')
    post '/accounts/new', account: { name: 'Sam Scanned', email: 'scanned@example.com' }, omniauth_signup: '1'
    account = Account.find_by(email: 'scanned@example.com')
    token = account.link_token_for_email

    scanner = Rack::Test::Session.new(app)
    scanner.get "/confirm_email/#{token}"
    assert_includes scanner.last_response.body, 'Confirm my email address'
    refute account.reload.email_confirmed
    assert_equal ['Google'], account.provider_links.map(&:provider)
    get '/accounts/edit'
    assert last_response.ok?

    get "/confirm_email/#{token}"
    assert_includes last_response.body, 'Confirm my email address'
    post '/accounts/confirm_email'
    assert account.reload.email_confirmed
    assert_equal ['Google'], account.provider_links.map(&:provider)
  end

  test 'the first sign in from a link elsewhere to an unconfirmed account signs out whoever signed up with its email' do
    start_omniauth_signup(email: 'squatted@example.com')
    post '/accounts/new', account: { name: 'Sid Squatter', email: 'squatted@example.com' }, omniauth_signup: '1'
    account = Account.find_by(email: 'squatted@example.com')
    get '/accounts/edit'
    assert last_response.ok?

    owner_browser = Rack::Test::Session.new(app)
    owner_browser.get "/e/some-event?link_token=#{account.link_token_for_email}&ref=email"
    assert_equal '/accounts/confirm_email', URI(owner_browser.last_response.location).path
    refute account.reload.email_confirmed
    get '/accounts/edit'
    assert last_response.redirect?
    owner_browser.get '/accounts/confirm_email'
    assert_includes owner_browser.last_response.body, 'We signed out other browsers'
    assert_includes owner_browser.last_response.body, 'data-method="post" href="/accounts/confirm_email/later"'
    assert_equal '/e/some-event?ref=email', owner_browser.last_request.session[:confirm_email_later]

    # Only the first time signs out: another link elsewhere keeps the owner's browser, though it asks again, as nobody has answered
    other_browser = Rack::Test::Session.new(app)
    other_browser.get '/', link_token: account.reload.link_token_for_email
    assert_equal '/accounts/confirm_email', URI(other_browser.last_response.location).path
    owner_browser.get '/accounts/edit'
    assert owner_browser.last_response.ok?

    # Confirming replaces the password and providers whoever signed up could sign back in with
    crypted_password = account.reload.crypted_password
    owner_browser.post '/accounts/confirm_email'
    assert account.reload.email_confirmed
    refute_equal crypted_password, account.crypted_password
    assert_empty account.provider_links
    owner_browser.get '/accounts/edit'
    assert owner_browser.last_response.ok?
  end

  test 'a mail scanner opening a link to an unconfirmed account first still leaves the owner asked to confirm' do
    start_omniauth_signup(email: 'prefetched@example.com')
    post '/accounts/new', account: { name: 'Pat Prefetched', email: 'prefetched@example.com' }, omniauth_signup: '1'
    account = Account.find_by(email: 'prefetched@example.com')

    # A HEAD request can't show the page asking, so it signs nobody out
    scanner = Rack::Test::Session.new(app)
    scanner.head "/e/some-event?link_token=#{account.link_token_for_email}"
    refute account.reload.ended_sessions_for_email_sign_in
    get '/accounts/edit'
    assert last_response.ok?

    # A GET does, but its scanner never answers, so the owner's next link asks
    scanner.get "/e/some-event?link_token=#{account.reload.link_token_for_email}"
    assert_equal '/accounts/confirm_email', URI(scanner.last_response.location).path
    assert account.reload.confirm_email_prompt_owed
    get '/accounts/edit'
    assert last_response.redirect?

    owner_browser = Rack::Test::Session.new(app)
    owner_browser.get '/', link_token: account.reload.link_token_for_email
    assert_equal '/accounts/confirm_email', URI(owner_browser.last_response.location).path
    owner_browser.post '/accounts/confirm_email'
    assert account.reload.email_confirmed
    refute account.confirm_email_prompt_owed
    assert_empty account.provider_links
  end

  test 'not now stops asking to confirm at each link sign in' do
    start_omniauth_signup(email: 'not-now@example.com')
    post '/accounts/new', account: { name: 'Nat Notnow', email: 'not-now@example.com' }, omniauth_signup: '1'
    account = Account.find_by(email: 'not-now@example.com')

    owner_browser = Rack::Test::Session.new(app)
    owner_browser.get "/e/some-event?link_token=#{account.link_token_for_email}&ref=email"
    assert_equal '/accounts/confirm_email', URI(owner_browser.last_response.location).path
    owner_browser.post '/accounts/confirm_email/later'
    assert_equal '/e/some-event?ref=email', URI(owner_browser.last_response.location).request_uri
    refute account.reload.confirm_email_prompt_owed
    refute account.email_confirmed

    other_browser = Rack::Test::Session.new(app)
    other_browser.get '/', link_token: account.reload.link_token_for_email
    assert other_browser.last_response.ok?
  end

  test 'confirming the email with a code elsewhere ends the session, provider and password of whoever signed up with it' do
    victim_email = 'signed-up-by-someone-else@example.com'
    start_omniauth_signup(email: victim_email)
    post '/accounts/new', account: { name: 'Someone Else', email: victim_email }, omniauth_signup: '1'
    account = Account.find_by(email: victim_email)
    assert account.provider_links.find_by(provider: 'Google').before_email_confirmed
    get '/accounts/edit'
    assert last_response.ok?
    crypted_password = account.crypted_password
    api_key = account.api_key
    ics_key = account.ensure_ics_key!

    victim_browser = Rack::Test::Session.new(app)
    victim_browser.get '/', sign_in_code: account.issue_sign_in_code!
    assert_includes victim_browser.last_response.body, 'Google had been connected to this account before its email address was confirmed'
    assert account.reload.email_confirmed
    assert_empty account.provider_links
    refute_equal crypted_password, account.crypted_password
    refute_equal api_key, account.api_key
    refute_equal ics_key, account.ics_key
    assert_nil Account.find_by(ics_key: ics_key)

    get '/accounts/edit'
    assert last_response.redirect?
    victim_browser.get '/accounts/edit'
    assert victim_browser.last_response.ok?
  end

  test 'confirming the email elsewhere resets a password set before it was confirmed' do
    account = FactoryBot.create(:account)
    sign_in_via_rack(account)
    assert_equal account.id.to_s, last_request.session[:account_id]

    victim_browser = Rack::Test::Session.new(app)
    victim_browser.get '/', sign_in_code: account.issue_sign_in_code!
    assert account.reload.email_confirmed
    refute account.password_matches?(account.password)

    get '/accounts/edit'
    assert last_response.redirect?
    sign_in_via_rack(account)
    assert_nil last_request.session[:account_id]
  end

  test 'confirming the email with a code in the browser that signed up keeps its provider' do
    sign_up_with_google(email: 'ethan@example.com')
    account = Account.find_by(email: 'ethan@example.com')
    crypted_password = account.crypted_password

    visit "/?sign_in_code=#{account.issue_sign_in_code!}"
    assert page.has_content?('Signed in with a sign in code')
    assert account.reload.email_confirmed
    refute account.provider_links.find_by(provider: 'Google').before_email_confirmed
    assert_equal crypted_password, account.crypted_password
    visit '/accounts/edit'
    assert page.has_field?('Full name', with: 'Alice Example')
  end

  test 'confirming the email with the link elsewhere ends the provider of whoever signed up with it' do
    start_omniauth_signup(email: 'linked-elsewhere@example.com')
    post '/accounts/new', account: { name: 'Lina Elsewhere', email: 'linked-elsewhere@example.com' }, omniauth_signup: '1'
    account = Account.find_by(email: 'linked-elsewhere@example.com')

    victim_browser = Rack::Test::Session.new(app)
    victim_browser.get "/confirm_email/#{account.link_token_for_email}"
    victim_browser.post '/accounts/confirm_email'
    assert account.reload.email_confirmed
    assert_empty account.provider_links
    get '/accounts/edit'
    assert last_response.redirect?
    victim_browser.get '/accounts/edit'
    assert victim_browser.last_response.ok?
  end

  test 'confirming the email with the link in the browser that signed up keeps its provider' do
    sign_up_with_google(email: 'linked-here@example.com')
    account = Account.find_by(email: 'linked-here@example.com')

    visit "/confirm_email/#{account.link_token_for_email}"
    click_button 'Confirm my email address'
    assert page.has_content?('Your email address was confirmed')
    assert account.reload.email_confirmed
    refute account.provider_links.find_by(provider: 'Google').before_email_confirmed
    visit '/accounts/edit'
    assert page.has_field?('Full name', with: 'Alice Example')
  end

  test 'a session from a link that changes the email with a code and confirms it there keeps its password and providers' do
    account = FactoryBot.create(:account)
    account.set(email_confirmed: true)
    account.provider_links.create!(provider: 'Google', provider_uid: 'google-uid-email-change', omniauth_hash: { 'uid' => 'google-uid-email-change' }, before_email_confirmed: false)
    crypted_password = account.crypted_password
    visit "/?link_token=#{account.link_token_for_email}"

    visit '/accounts/edit'
    fill_in 'Email', with: 'changed-here@example.com'
    click_button 'Save profile'
    assert page.has_content?('to change your email, enter the code below, then make the change again')
    assert_equal account.email, account.reload.email
    enter_sign_in_code(account)
    assert page.has_current_path?('/accounts/edit')
    fill_in 'Email', with: 'changed-here@example.com'
    click_button 'Save profile'
    assert page.has_content?('Please click the link in the email we sent to confirm your new email address')
    assert_equal 'changed-here@example.com', account.reload.email

    visit "/confirm_email/#{account.link_token}"
    click_button 'Confirm my email address'
    assert page.has_content?('Your email address was confirmed')
    assert account.reload.email_confirmed
    assert_equal crypted_password, account.crypted_password
    refute account.provider_links.find_by(provider: 'Google').before_email_confirmed
    # Still signed in, with the session token confirming gave it
    visit '/accounts/edit'
    assert page.has_field?('Email', with: 'changed-here@example.com')
  end

  test 'confirming the email elsewhere removes providers connected before it was tracked' do
    account = FactoryBot.create(:account)
    link = account.provider_links.create!(provider: 'Google', provider_uid: 'google-uid-legacy', omniauth_hash: { 'uid' => 'google-uid-legacy' })
    ProviderLink.collection.update_one({ _id: link.id }, { '$unset' => { before_email_confirmed: 1 } })

    clear_cookies
    get '/', sign_in_code: account.issue_sign_in_code!
    assert account.reload.email_confirmed
    assert_empty account.provider_links
  end

  test 'a session from a link that then enters a code confirms the email as someone else' do
    start_omniauth_signup(email: 'link-then-code@example.com')
    post '/accounts/new', account: { name: 'Lee Linked', email: 'link-then-code@example.com' }, omniauth_signup: '1'
    account = Account.find_by(email: 'link-then-code@example.com')

    other_browser = Rack::Test::Session.new(app)
    other_browser.get '/', link_token: account.link_token_for_email
    refute account.reload.email_confirmed
    other_browser.get '/', sign_in_code: account.issue_sign_in_code!
    assert account.reload.email_confirmed
    assert_empty account.provider_links
  end

  test 'changing the email puts its providers on trial until the new address is confirmed' do
    account = FactoryBot.create(:account)
    sign_in(account)
    account.provider_links.create!(provider: 'Google', provider_uid: 'google-uid-before-change', omniauth_hash: { 'uid' => 'google-uid-before-change' }, before_email_confirmed: false)
    visit '/accounts/edit'
    fill_in 'Email', with: 'someone-elses@example.com'
    click_button 'Save profile'
    assert page.has_content?('Please click the link in the email we sent to confirm your new email address')
    assert_equal 'someone-elses@example.com', account.reload.email
    refute account.email_confirmed
    assert account.provider_links.find_by(provider: 'Google').before_email_confirmed

    # The address's owner signs in with a code in their own browser
    Capybara.using_session(:owner_browser) do
      visit "/?sign_in_code=#{Account.find(account.id).issue_sign_in_code!}"
      assert page.has_content?('Signed in with a sign in code')
    end
    assert account.reload.email_confirmed
    assert_empty account.provider_links
  end

  test 'email previews do not show the signed-in account a working link token' do
    create_event(prices: [0])
    sign_in_with_rack(@account)
    @account.generate_link_token!

    %w[ticket_email_preview reminder_email_preview feedback_request_email_preview].each do |preview|
      get "/e/#{@event.slug}/#{preview}"
      assert last_response.ok?, preview
      refute_includes last_response.body, @account.reload.link_token, preview
    end
  end

  test 'a session from before the set up marker confirms the email as someone else' do
    account = FactoryBot.create(:account)
    account.provider_links.create!(provider: 'Google', provider_uid: 'google-uid-old-session', omniauth_hash: { 'uid' => 'google-uid-old-session' }, before_email_confirmed: true)
    clear_cookies
    env 'rack.session', { 'account_id' => account.id.to_s, 'session_token' => account.session_token! }
    get '/accounts/edit'
    assert last_response.ok?

    get '/', sign_in_code: account.issue_sign_in_code!
    assert account.reload.email_confirmed
    assert_empty account.provider_links
    # Still signed in, with the token of the revocation (env above would replay the old session on another request)
    assert_equal account.session_token, last_request.session[:session_token]
  end

  test 'saving a provider link from before before_email_confirmed keeps it counted as before confirmation' do
    account = FactoryBot.create(:account)
    link = account.provider_links.create!(provider: 'Google', provider_uid: 'google-uid-legacy-save', omniauth_hash: { 'uid' => 'google-uid-legacy-save' })
    ProviderLink.collection.update_one({ _id: link.id }, { '$unset' => { before_email_confirmed: 1 } })

    loaded = Account.find(account.id)
    loaded.provider_links.build(provider: 'Ethereum', provider_uid: '0xabc', omniauth_hash: { 'uid' => '0xabc' }, before_email_confirmed: true)
    loaded.save!
    refute_equal false, ProviderLink.collection.find(_id: link.id).first['before_email_confirmed']

    ProviderLink.find(link.id).save!
    assert ProviderLink.collection.find(_id: link.id).first['before_email_confirmed']
  end

  test 'signing up with Google under its verified Gmail address confirms the email' do
    sign_up_with_google(email: 'alice.example@gmail.com')
    account = Account.find_by(email: 'alice.example@gmail.com')
    assert account.email_confirmed
    refute account.provider_links.find_by(provider: 'Google').before_email_confirmed
  end

  test 'signing up with Google under another domain\'s address leaves the email unconfirmed' do
    sign_up_with_google
    account = Account.find_by(email: 'alice-oauth@example.com')
    refute account.email_confirmed
    assert account.provider_links.find_by(provider: 'Google').before_email_confirmed
  end

  test 'signing up with Google under its Gmail address but another email leaves the email unconfirmed' do
    sign_up_with_google(email: 'alice.example@gmail.com', signup_email: 'someone-else@gmail.com')
    account = Account.find_by(email: 'someone-else@gmail.com')
    refute account.email_confirmed
    assert account.provider_links.find_by(provider: 'Google').before_email_confirmed
  end

  # The form after Google always says omniauth_signup, so only a hand-made request leaves it out
  test 'leftover omniauth session is not linked on a later signup' do
    start_omniauth_signup
    later = FactoryBot.build_stubbed(:account)
    post_new_account(later)

    created = Account.find_by(email: later.email.downcase)
    assert created
    assert_equal 0, created.provider_links.count
  end

  test 'visiting signup again drops an abandoned omniauth session' do
    start_omniauth_signup
    get '/accounts/new'
    assert_nil last_request.session['omniauth.auth']
    refute_includes last_response.body, 'name="omniauth_signup"'
  end

  test 'abandoned omniauth session is not linked after a later visit to signup' do
    visit_omniauth_as(uid: 'google-uid-1')
    assert page.has_content?("isn't yet connected to a Dandelion account")
    visit '/accounts/new'
    assert page.has_button?('Sign up')
    assert page.has_no_css?('input[name="omniauth_signup"]', visible: :all)

    later = FactoryBot.build_stubbed(:account)
    fill_signup_form(later)
    assert page.has_content?('Welcome to Dandelion!')

    created = Account.find_by(email: later.email.downcase)
    assert created
    assert_equal 0, created.provider_links.count
  end

  test 'omniauth signup form links the provider' do
    visit_omniauth_as(uid: 'google-uid-1')
    later = FactoryBot.build_stubbed(:account)
    fill_signup_form(later)
    assert page.has_content?('Welcome to Dandelion!')

    created = Account.find_by(email: later.email.downcase)
    assert created
    link = created.provider_links.find_by(provider: 'Google')
    assert link
    assert_equal 'google-uid-1', link.provider_uid
  end

  test 'omniauth session is kept across failed signup validation' do
    visit_omniauth_as(uid: 'google-uid-1')
    # Past the browser's own checks, but not the account's
    fill_in 'Full name', with: 'www.example.com'
    click_button 'Sign up'
    assert page.has_content?('Some errors prevented the account from being saved')

    later = FactoryBot.build_stubbed(:account)
    fill_signup_form(later)
    assert page.has_content?('Welcome to Dandelion!')

    created = Account.find_by(email: later.email.downcase)
    assert created
    assert created.provider_links.find_by(provider: 'Google', provider_uid: 'google-uid-1')
  end

  test 'omniauth leftover is cleared when signup email already exists' do
    existing = FactoryBot.create(:account)
    start_omniauth_signup
    post_new_account(FactoryBot.build_stubbed(:account, email: existing.email), omniauth_signup: '1')

    later = FactoryBot.build_stubbed(:account)
    post_new_account(later)

    created = Account.find_by(email: later.email.downcase)
    assert created
    assert_equal 0, created.provider_links.count
  end

  test 'siwe request phase renders a message bound to this site' do
    clear_cookies
    get '/auth/ethereum'
    follow_redirect!
    template = siwe_template_from(last_response)

    assert_includes template, "127.0.0.1:#{ENV['PORT']} wants you to sign in with your Ethereum account:"
    assert_includes template, "URI: #{ENV['BASE_URI']}/auth/ethereum/callback"
    assert_match(/^Nonce: [A-Za-z0-9]{17}$/, template)
    assert_includes template, 'Expiration Time:'
  end

  test 'siwe page sends a reload back for a fresh nonce' do
    clear_cookies
    get '/auth/ethereum'
    follow_redirect!
    assert last_response.ok?

    get '/accounts/ethereum'
    assert last_response.redirect?
    assert_equal '/auth/ethereum', URI(last_response.location).path
  end

  test 'siwe signs in an account whose wallet is linked, matching the address case-insensitively' do
    key = OpenSSL::PKey::EC.generate('secp256k1')
    address = siwe_address(key)
    account = FactoryBot.create(:account)
    account.provider_links.create!(provider: 'Ethereum', provider_uid: address.downcase, omniauth_hash: { 'uid' => address.downcase })

    message, signature = siwe_start_and_sign(key)
    post '/auth/ethereum/callback', siwe_message: message, siwe_signature: signature

    assert last_response.redirect?
    assert_equal '/', URI(last_response.location).path
    assert_equal 1, account.reload.sign_ins.count
  end

  test 'siwe offers signup with a checksummed uid for an unknown wallet' do
    key = OpenSSL::PKey::EC.generate('secp256k1')
    message, signature = siwe_start_and_sign(key)
    post '/auth/ethereum/callback', siwe_message: message, siwe_signature: signature

    assert last_response.ok?
    assert_includes last_response.body, "isn't yet connected to a Dandelion account"
    assert_equal siwe_address(key), last_request.session['omniauth.auth']['uid']
  end

  test 'siwe accepts a browser form payload with CRLF newlines' do
    key = OpenSSL::PKey::EC.generate('secp256k1')
    message, signature = siwe_start_and_sign(key)
    post '/auth/ethereum/callback', siwe_message: message.gsub("\n", "\r\n"), siwe_signature: signature

    assert last_response.ok?
    assert_includes last_response.body, "isn't yet connected to a Dandelion account"
  end

  test 'siwe rejects a replayed signature' do
    key = OpenSSL::PKey::EC.generate('secp256k1')
    message, signature = siwe_start_and_sign(key)
    post '/auth/ethereum/callback', siwe_message: message, siwe_signature: signature
    assert last_response.ok?

    post '/auth/ethereum/callback', siwe_message: message, siwe_signature: signature
    assert_siwe_failure 'missing_nonce'
  end

  test 'siwe rejects a callback via GET' do
    key = OpenSSL::PKey::EC.generate('secp256k1')
    message, signature = siwe_start_and_sign(key)
    get '/auth/ethereum/callback', siwe_message: message, siwe_signature: signature
    assert_siwe_failure 'invalid_request'

    post '/auth/ethereum/callback', siwe_message: message, siwe_signature: signature
    assert_siwe_failure 'missing_nonce'
  end

  test 'siwe rejects a message signed for a different nonce or domain' do
    key = OpenSSL::PKey::EC.generate('secp256k1')
    message, = siwe_start_and_sign(key)

    forged = message.sub(/^Nonce: .*$/, "Nonce: #{Siwe.generate_nonce}")
    post '/auth/ethereum/callback', siwe_message: forged, siwe_signature: siwe_sign(key, forged)
    assert_siwe_failure 'nonce_mismatch'

    message, = siwe_start_and_sign(key)
    forged = message.sub(/\A[^ ]+/, 'evil.example')
    post '/auth/ethereum/callback', siwe_message: forged, siwe_signature: siwe_sign(key, forged)
    assert_siwe_failure 'domain_mismatch'
  end

  test 'siwe rejects a signature from a different wallet' do
    key = OpenSSL::PKey::EC.generate('secp256k1')
    other_key = OpenSSL::PKey::EC.generate('secp256k1')
    message, = siwe_start_and_sign(key)
    post '/auth/ethereum/callback', siwe_message: message, siwe_signature: siwe_sign(other_key, message)
    assert_siwe_failure 'invalid_signature'
  end

  test 'Bluesky sign-in pushes the authorization request and signs in the account connected to the DID' do
    account = FactoryBot.create(:account)
    account.provider_links.create!(provider: 'Bluesky', provider_uid: ATPROTO_ALICE, omniauth_hash: { 'info' => { 'did' => ATPROTO_ALICE } })
    network = atproto_network
    with_atproto_network(network) do
      state = start_atproto_sign_in('@alice.test')
      location = URI(last_response.location)
      assert_equal "#{ATPROTO_ALICE_AS}/oauth/authorize", "#{location.scheme}://#{location.host}#{location.path}"
      assert_equal({ 'client_id' => AtprotoKeyManager.client_id, 'request_uri' => network[:par][:request_uri] }, Rack::Utils.parse_query(location.query))
      assert_equal 'alice.test', network[:par][:login_hint]
      get '/auth/atproto/callback', code: network[:par][:code], state: state, iss: ATPROTO_ALICE_AS
    end

    # The server's first PAR asked for a DPoP nonce, and the token request used the same DPoP key
    assert_equal 2, network[:requests].count("#{ATPROTO_ALICE_AS}/oauth/par")
    assert_equal 1, network[:requests].count("#{ATPROTO_ALICE_AS}/oauth/token")
    assert last_response.redirect?
    assert_equal '/', URI(last_response.location).path
    assert_equal account.id.to_s, last_request.session[:account_id]
    assert_nil last_request.session[OmniAuth::Strategies::Atproto::FLOW_KEY]
  end

  test 'Bluesky sign-in keeps the query strings of the authorization server endpoints' do
    account = FactoryBot.create(:account)
    account.provider_links.create!(provider: 'Bluesky', provider_uid: ATPROTO_ALICE, omniauth_hash: { 'info' => { 'did' => ATPROTO_ALICE } })
    network = atproto_network
    metadata_url = "#{ATPROTO_ALICE_AS}/.well-known/oauth-authorization-server"
    network[:http][metadata_url] = JSON.parse(network[:http][metadata_url]).merge(
      'authorization_endpoint' => "#{ATPROTO_ALICE_AS}/oauth/authorize?tenant=a",
      'pushed_authorization_request_endpoint' => "#{ATPROTO_ALICE_AS}/oauth/par?tenant=a",
      'token_endpoint' => "#{ATPROTO_ALICE_AS}/oauth/token?tenant=a"
    ).to_json
    with_atproto_network(network) do
      state = start_atproto_sign_in('alice.test')
      query = Rack::Utils.parse_query(URI(last_response.location).query)
      assert_equal({ 'tenant' => 'a', 'client_id' => AtprotoKeyManager.client_id, 'request_uri' => network[:par][:request_uri] }, query)
      get '/auth/atproto/callback', code: network[:par][:code], state: state, iss: ATPROTO_ALICE_AS
    end

    # The fake server refuses a DPoP proof whose htu has the query (RFC 9449 4.2)
    assert_includes network[:requests], "#{ATPROTO_ALICE_AS}/oauth/token?tenant=a"
    assert_equal account.id.to_s, last_request.session[:account_id]
  end

  test 'Bluesky discovery that fails after the handle resolves leaves no sign-in in the session' do
    network = atproto_network
    with_atproto_network(network) do
      start_atproto_sign_in('alice.test')
      assert_equal ATPROTO_ALICE, last_request.session[OmniAuth::Strategies::Atproto::FLOW_KEY]['did']

      # Each way discovery can fail once mallory.test has resolved to a DID
      [
        -> { network[:http]["#{ATPROTO_MALLORY_PDS}/.well-known/oauth-protected-resource"] = SsrfFilter::Error.new('private address') },
        -> { network[:http]["#{ATPROTO_MALLORY_PDS}/.well-known/oauth-protected-resource"] = 'not json' },
        -> { network[:http]["#{ATPROTO_MALLORY_PDS}/.well-known/oauth-protected-resource"] = Net::ReadTimeout.new },
        -> { network[:pds][ATPROTO_MALLORY] = DIDKit::APIError.new(atproto_response('', code: '500')) },
        -> { network[:par_error] = 'invalid_request' }
      ].each do |break_discovery|
        start_atproto_sign_in('alice.test')
        network.replace(atproto_network)
        break_discovery.call
        get '/auth/atproto', handle: 'mallory.test'

        assert_atproto_failure 'invalid_auth_server'
        assert_nil last_request.session[OmniAuth::Strategies::Atproto::FLOW_KEY]
      end
    end
  end

  test 'Bluesky callback is refused when the token DID names another authorization server' do
    account = FactoryBot.create(:account)
    account.provider_links.create!(provider: 'Bluesky', provider_uid: ATPROTO_ALICE, omniauth_hash: { 'info' => { 'did' => ATPROTO_ALICE } })
    network = atproto_network
    with_atproto_network(network) do
      # At request time alice's DID document pointed at mallory's PDS, whose authorization server then
      # issues a token for alice. The DID's own PDS, resolved on callback, names alice's server
      network[:pds][ATPROTO_ALICE] = ATPROTO_MALLORY_PDS
      network[:token_sub] = ATPROTO_ALICE
      state = start_atproto_sign_in('alice.test')
      assert_equal ATPROTO_MALLORY_AS, last_request.session[OmniAuth::Strategies::Atproto::FLOW_KEY]['issuer']
      network[:pds][ATPROTO_ALICE] = ATPROTO_ALICE_PDS
      get '/auth/atproto/callback', code: network[:par][:code], state: state, iss: ATPROTO_MALLORY_AS
    end

    assert_equal 1, network[:requests].count("#{ATPROTO_MALLORY_AS}/oauth/token")
    assert_atproto_failure 'invalid_issuer', "Token issuer is not the DID's authorization server"
    assert_nil last_request.session[:account_id]
  end

  test 'Bluesky callback is refused when the token DID is not the one the handle resolved to' do
    account = FactoryBot.create(:account)
    account.provider_links.create!(provider: 'Bluesky', provider_uid: ATPROTO_ALICE, omniauth_hash: { 'info' => { 'did' => ATPROTO_ALICE } })
    network = atproto_network
    network[:token_sub] = ATPROTO_ALICE # mallory's own server vouches for alice
    with_atproto_network(network) do
      state = start_atproto_sign_in('mallory.test')
      get '/auth/atproto/callback', code: network[:par][:code], state: state, iss: ATPROTO_MALLORY_AS
    end

    assert_atproto_failure 'invalid_did', 'Token sub is not the DID for this sign-in'
    assert_nil last_request.session[:account_id]
  end

  test 'Bluesky callback is refused with another issuer, another sign-in state, a refusal or a handle' do
    account = FactoryBot.create(:account)
    account.provider_links.create!(provider: 'Bluesky', provider_uid: ATPROTO_ALICE, omniauth_hash: { 'info' => { 'did' => ATPROTO_ALICE } })
    network = atproto_network
    with_atproto_network(network) do
      state = start_atproto_sign_in('alice.test')
      get '/auth/atproto/callback', code: network[:par][:code], state: state, iss: ATPROTO_MALLORY_AS
      assert_atproto_failure 'invalid_issuer'

      state = start_atproto_sign_in('alice.test')
      get '/auth/atproto/callback', code: network[:par][:code], state: state
      assert_atproto_failure 'invalid_issuer'

      # Only the latest sign-in's state is accepted, and only once
      earlier_state = start_atproto_sign_in('alice.test')
      state = start_atproto_sign_in('alice.test')
      get '/auth/atproto/callback', code: network[:par][:code], state: earlier_state, iss: ATPROTO_ALICE_AS
      assert_atproto_failure 'csrf_detected'
      get '/auth/atproto/callback', code: network[:par][:code], state: state, iss: ATPROTO_ALICE_AS
      assert_atproto_failure 'missing_did'

      state = start_atproto_sign_in('alice.test')
      get '/auth/atproto/callback', error: 'access_denied', state: state, iss: ATPROTO_ALICE_AS
      assert_atproto_failure 'access_denied'

      # A handle on the callback doesn't start discovery over
      state = start_atproto_sign_in('mallory.test')
      network[:token_sub] = ATPROTO_ALICE
      get '/auth/atproto/callback', code: network[:par][:code], state: state, iss: ATPROTO_MALLORY_AS, handle: 'alice.test'
      assert_atproto_failure 'invalid_did'
    end

    assert_nil last_request.session[:account_id]
  end

  test 'Bluesky sign-in refuses what is not a handle or DID without looking it up' do
    network = atproto_network
    with_atproto_network(network) do
      ['', 'localhost', 'alice.test/../x', 'did:key:z6Mk'].each do |identifier|
        get '/auth/atproto', handle: identifier
        assert_atproto_failure 'invalid_handle'
      end
    end
    assert_empty network[:requests]
  end

  private

  # What the stubbed network serves: handles to DIDs, DIDs to PDSs, and SsrfFilter's GET URLs to bodies (or errors).
  # Each authorization server's PAR and token endpoints are in with_atproto_network
  def atproto_network
    http = {}
    [[ATPROTO_ALICE_PDS, ATPROTO_ALICE_AS], [ATPROTO_MALLORY_PDS, ATPROTO_MALLORY_AS]].each do |pds, issuer|
      http["#{pds}/.well-known/oauth-protected-resource"] = { authorization_servers: [issuer] }.to_json
      http["#{issuer}/.well-known/oauth-authorization-server"] = {
        issuer: issuer, authorization_endpoint: "#{issuer}/oauth/authorize", token_endpoint: "#{issuer}/oauth/token",
        pushed_authorization_request_endpoint: "#{issuer}/oauth/par", require_pushed_authorization_requests: true,
        authorization_response_iss_parameter_supported: true, scopes_supported: %w[atproto]
      }.to_json
    end
    {
      handles: { 'alice.test' => ATPROTO_ALICE, 'mallory.test' => ATPROTO_MALLORY },
      pds: { ATPROTO_ALICE => ATPROTO_ALICE_PDS, ATPROTO_MALLORY => ATPROTO_MALLORY_PDS },
      http: http,
      requests: []
    }
  end

  def atproto_response(body, code: '200', headers: {})
    response = Net::HTTPResponse::CODE_TO_OBJ[code].new('1.1', code, '')
    headers.each { |name, value| response[name] = value }
    response.instance_variable_set(:@body, body)
    response.instance_variable_set(:@read, true)
    response
  end

  # A stubbed authorization server's PAR or token endpoint. Like a real one, it checks the client assertion is
  # signed with Dandelion's key for this server, asks for a DPoP nonce before accepting a proof, and gives the
  # token only for the code it issued, to the DPoP key and PKCE verifier the PAR used
  def atproto_token_endpoint(network, url, options, client_key)
    endpoint = url.split('?').first
    issuer = endpoint.delete_suffix('/oauth/par').delete_suffix('/oauth/token')
    form = Rack::Utils.parse_query(options[:body])
    JWT.decode(form['client_assertion'], client_key, true, algorithm: 'ES256', aud: issuer, verify_aud: true)
    jwk = JWT::JWK.import(JWT.decode(options[:headers]['DPoP'], nil, false)[1]['jwk'])
    proof = JWT.decode(options[:headers]['DPoP'], jwk.verify_key, true, algorithm: 'ES256')[0]
    nonce = "nonce-#{issuer}"
    reply = ->(body, code = '200') { atproto_response(body.to_json, code: code, headers: { 'DPoP-Nonce' => nonce }) }
    return reply.call({ error: 'use_dpop_nonce' }, '400') unless proof['nonce'] == nonce && proof['htu'] == endpoint && proof['htm'] == 'POST'

    thumbprint = JWT::JWK::Thumbprint.new(jwk).to_s
    if endpoint.end_with?('/oauth/par')
      return reply.call({ error: network[:par_error] }, '400') if network[:par_error]

      network[:par] = { issuer: issuer, thumbprint: thumbprint, challenge: form['code_challenge'], login_hint: form['login_hint'],
                        request_uri: "urn:ietf:params:oauth:request_uri:#{SecureRandom.hex(4)}", code: SecureRandom.hex(4) }
      reply.call({ request_uri: network[:par][:request_uri], expires_in: 60 }, '201')
    else
      par = network[:par]
      verified = par[:issuer] == issuer && par[:thumbprint] == thumbprint && form['code'] == par[:code] &&
                 Base64.urlsafe_encode64(Digest::SHA256.digest(form['code_verifier']), padding: false) == par[:challenge]
      return reply.call({ error: 'invalid_grant' }, '400') unless verified

      sub = network[:token_sub] || { ATPROTO_ALICE_AS => ATPROTO_ALICE, ATPROTO_MALLORY_AS => ATPROTO_MALLORY }[issuer]
      reply.call({ access_token: 'token', token_type: 'DPoP', expires_in: 3600, scope: 'atproto', sub: sub })
    end
  end

  # Stubs DIDKit, SsrfFilter, Dandelion's client key and the profile lookup with network, so no request leaves the test.
  # The token's sub is network[:token_sub], or else the DID the sign-in's handle resolved to
  def with_atproto_network(network, &)
    fetch = ->(value) { value.is_a?(Exception) ? raise(value) : value }
    resolver = Object.new
    resolver.define_singleton_method(:resolve_handle) { |handle| network[:handles][handle] }
    resolver.define_singleton_method(:resolve_did) do |did|
      pds = fetch.call(network[:pds][did.to_s])
      Struct.new(:pds_endpoint).new(pds)
    end
    ssrf_get = lambda do |url, _options|
      network[:requests] << url
      atproto_response(fetch.call(network[:http].fetch(url) { raise SsrfFilter::Error, "unexpected request to #{url}" }))
    end
    client_key = OpenSSL::PKey::EC.generate('prime256v1')
    ssrf_post = lambda do |url, options|
      network[:requests] << url
      atproto_token_endpoint(network, url, options, client_key)
    end
    profile_client = Object.new
    profile_client.define_singleton_method(:get_profile) { |_actor| nil }

    DIDKit::Resolver.stub(:new, resolver) do
      SsrfFilter.stub(:get, ssrf_get) do
        SsrfFilter.stub(:post, ssrf_post) do
          AtprotoKeyManager.stub(:current_private_key, client_key) do
            AtprotoKeyManager.stub(:current_jwk, AtprotoKeyManager.build_jwk(client_key)) do
              AtprotoClient.stub(:new, profile_client, &)
            end
          end
        end
      end
    end
  end

  # The sign-in failed with OmniAuth's message key, and with error's message if given
  def assert_atproto_failure(key, error = nil)
    assert last_response.redirect?
    location = URI(last_response.location)
    assert_equal '/auth/failure', location.path
    assert_equal key, Rack::Utils.parse_query(location.query)['message']
    assert_equal error, last_request.env['omniauth.error'].message if error
  end

  # Starts signing in with handle, returning the OAuth state it pushed to the authorization server
  def start_atproto_sign_in(handle)
    get '/auth/atproto', handle: handle
    network_state = last_request.session[OmniAuth::Strategies::Atproto::FLOW_KEY]&.dig('state')
    assert network_state, "Sign-in with #{handle} didn't start: #{last_response.location}"
    network_state
  end

  # Comes back from Google, in the browser, as this Google account
  def visit_omniauth_as(uid:, email: 'alice-oauth@example.com')
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: 'google_oauth2', uid: uid, info: { name: 'Alice Example', email: email }
    )
    visit '/auth/google_oauth2'
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  # Signs up with Google, in the form it fills in, as Alice Example under signup_email (Google's email unless given)
  def sign_up_with_google(email: 'alice-oauth@example.com', signup_email: nil)
    visit_omniauth_as(uid: 'google-uid-1', email: email)
    assert page.has_content?("isn't yet connected to a Dandelion account")
    fill_in 'Email', with: signup_email if signup_email
    click_button 'Sign up'
    assert page.has_content?('Welcome to Dandelion!')
  end

  # On the page asking for the sign in code just emailed
  def enter_sign_in_code(account)
    fill_in 'code', with: Account.find(account.id).issue_sign_in_code!
    click_button 'Submit'
  end

  # Buttons that ask first, in a popover whose button is named label
  def click_button_and_confirm(label, button: label)
    click_button button
    # The popover hangs off the page
    page.document.find('.popover').click_button label
  end

  def siwe_template_from(response)
    assert response.ok?
    match = response.body.match(/id="siwe_template" value="([^"]*)"/)
    assert match, 'siwe_template input not found'
    CGI.unescapeHTML(match[1])
  end

  def siwe_start_and_sign(key)
    clear_cookies
    get '/auth/ethereum'
    follow_redirect!
    message = siwe_template_from(last_response).sub(OmniAuth::Strategies::Ethereum::ADDRESS_PLACEHOLDER, siwe_address(key).downcase)
    [message, siwe_sign(key, message)]
  end

  def siwe_address(key)
    public_key = key.public_key.to_octet_string(:uncompressed)
    Siwe::Crypto.checksum_address("0x#{Siwe::Crypto.keccak256(public_key.byteslice(1, 64)).byteslice(-20, 20).unpack1('H*')}")
  end

  def siwe_sign(key, message)
    digest = Siwe::Crypto.eip191_hash(message)
    r, s = OpenSSL::ASN1.decode(key.dsa_sign_asn1(digest)).value.map { |v| v.value.to_i }
    address = siwe_address(key)
    [27, 28].each do |v|
      signature = "0x#{r.to_s(16).rjust(64, '0')}#{s.to_s(16).rjust(64, '0')}#{v.to_s(16)}"
      return signature if Siwe::Crypto.recover_address(message, signature) == address
    end
    flunk 'could not produce a recoverable signature'
  end

  def assert_siwe_failure(reason)
    assert last_response.redirect?, "expected a redirect to /auth/failure, got #{last_response.status}"
    location = URI(last_response.location)
    assert_equal '/auth/failure', location.path
    assert_includes Rack::Utils.parse_query(location.query)['message'], reason
  end

  def sign_in_via_rack(account)
    clear_cookies
    post '/auth/account/callback', email: account.email, password: account.password
  end

  def omniauth_callback_as(uid:)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: 'google_oauth2', uid: uid, info: { name: 'Alice Example', email: 'alice-oauth@example.com' }
    )
    get '/auth/google_oauth2'
    follow_redirect! while last_response.redirect?
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end

  def start_omniauth_signup(email: 'alice-oauth@example.com')
    clear_cookies
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: 'google_oauth2',
      uid: 'google-uid-1',
      info: { name: 'Alice Example', email: email }
    )
    get '/auth/google_oauth2'
    follow_redirect! while last_response.redirect?
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end
end
