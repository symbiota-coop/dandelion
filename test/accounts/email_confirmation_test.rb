require_relative '../test_config'
require_relative '../helpers/sign_in_helpers'

# Confirming the email, with its link or a code, and what that does to sessions, providers and passwords set before it
class AccountEmailConfirmationTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include SignInHelpers

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
end
