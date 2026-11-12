# Helpers the sign-in test files (test/accounts) share
module SignInHelpers
  # Comes back from Google, in the browser, as this Google account
  def visit_omniauth_as(uid:, email: 'alice-oauth@example.com')
    as_google_account(uid: uid, email: email) { visit '/auth/google_oauth2' }
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

  def sign_in_via_rack(account)
    clear_cookies
    post '/auth/account/callback', email: account.email, password: account.password
  end

  # Comes back from Google, through Rack, as this Google account
  def omniauth_callback_as(uid:, email: 'alice-oauth@example.com')
    as_google_account(uid: uid, email: email) do
      get '/auth/google_oauth2'
      follow_redirect! while last_response.redirect?
    end
  end

  def start_omniauth_signup(email: 'alice-oauth@example.com')
    clear_cookies
    omniauth_callback_as(uid: 'google-uid-1', email: email)
  end

  # While the block runs, signing in with Google signs in as Alice Example, with this uid and email
  def as_google_account(uid:, email:)
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: 'google_oauth2', uid: uid, info: { name: 'Alice Example', email: email }
    )
    yield
  ensure
    OmniAuth.config.test_mode = false
    OmniAuth.config.mock_auth[:google_oauth2] = nil
  end
end
