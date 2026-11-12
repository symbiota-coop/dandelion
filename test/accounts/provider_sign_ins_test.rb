require_relative '../test_config'
require_relative '../helpers/sign_in_helpers'

# Signing in and up with Google, Ethereum (SIWE) or Bluesky, and connecting providers
class AccountProviderSignInsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include SignInHelpers

  ATPROTO_ALICE = 'did:plc:alice'.freeze

  ATPROTO_ALICE_PDS = 'https://pds.alice.test'.freeze

  ATPROTO_ALICE_AS = 'https://as.alice.test'.freeze

  ATPROTO_MALLORY = 'did:plc:mallory'.freeze

  ATPROTO_MALLORY_PDS = 'https://pds.mallory.test'.freeze

  ATPROTO_MALLORY_AS = 'https://as.mallory.test'.freeze

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
end
