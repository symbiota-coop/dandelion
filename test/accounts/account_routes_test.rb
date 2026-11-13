require_relative '../test_config'

# An account's smaller routes: unsubscribing from all emails, resending the confirmation email, resetting someone's
# password, the lists on a profile of what someone's in, following and starring people, the old /accounts/:id URLs,
# and the sign-in pages around providers
class AccountRoutesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  XHR = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }.freeze

  # An account that has signed in, so its profile is public
  def public_account(**attrs)
    FactoryBot.create(:account, has_signed_in: true, **attrs)
  end

  test 'a link signs someone in to unsubscribe them from all emails, and only them' do
    covers_route 'GET /accounts/unsubscribe'
    account = FactoryBot.create(:account)
    other = FactoryBot.create(:account)
    account.generate_link_token!

    get '/accounts/unsubscribe', link_token: account.link_token
    assert_equal '/accounts/subscriptions', URI(last_response.location).path
    assert account.reload.unsubscribed
    refute other.reload.unsubscribed
  end

  test 'unsubscribing from all emails with a forged link changes nobody' do
    account = FactoryBot.create(:account)
    account.generate_link_token!

    get '/accounts/unsubscribe', link_token: "#{account.link_token}x"
    assert_equal '/accounts/sign_in', URI(last_response.location).path
    get '/accounts/unsubscribe'
    assert_equal '/accounts/new', URI(last_response.location).path
    refute account.reload.unsubscribed
  end

  test 'someone asks for their confirmation email again' do
    covers_route 'POST /confirm_email'
    account = FactoryBot.create(:account)
    sign_in(account)
    account.set(email_confirmed: false)
    visit '/accounts/edit'
    email = recorded_email do
      click_link 'Resend confirmation email'
      assert page.has_content?('Please click the link in the email to confirm your email address.')
    end
    assert_equal [account.email], email.recipients
    assert_equal 'Confirm your email address', email.subject_line
  end

  test 'a site admin resets a password, which works and signs the account out' do
    covers_route 'POST /u/:username/reset_password'
    account = FactoryBot.create(:account, failed_sign_in_attempts: 5)
    sign_in_with_rack(FactoryBot.create(:account, admin: true))

    post "/u/#{account.username}/reset_password"
    password = JSON.parse(last_response.body)['password']
    assert password.present?
    assert_equal account.id, Account.authenticate(account.email, password).id
    assert_equal 0, account.reload.failed_sign_in_attempts.to_i
  end

  test "someone who may reset passwords resets other people's, but not a site admin's" do
    resetter = FactoryBot.create(:account, can_reset_passwords: true)
    account = FactoryBot.create(:account)
    admin = FactoryBot.create(:account, admin: true)
    sign_in_with_rack(resetter)

    post "/u/#{account.username}/reset_password"
    assert JSON.parse(last_response.body)['password'].present?

    post "/u/#{admin.username}/reset_password"
    assert_equal 403, last_response.status
    assert Account.authenticate(admin.email, admin.password)
  end

  test "nobody else can reset someone's password" do
    account = FactoryBot.create(:account)
    post "/u/#{account.username}/reset_password"
    refute_includes last_response.body, 'password'

    sign_in_with_rack(FactoryBot.create(:account))
    post "/u/#{account.username}/reset_password"
    refute_includes last_response.body, 'password'
    assert Account.authenticate(account.email, account.password)
  end

  test "an account's activities, local groups and gatherings show to people signed in, leaving out the hidden ones" do
    covers_route 'GET /u/:username/activities'
    covers_route 'GET /u/:username/local_groups'
    covers_route 'GET /u/:username/gatherings'
    account = public_account(activities_privacy: 'Public', local_groups_privacy: 'Public', gatherings_privacy: 'Public')
    activity = FactoryBot.create(:activity, name: 'Shown Activity')
    hidden_activity = FactoryBot.create(:activity, name: 'Hidden Activity')
    account.activityships.create!(activity: activity)
    account.activityships.create!(activity: hidden_activity).set(hide_membership: true)
    local_group = FactoryBot.create(:local_group, name: 'Shown Group')
    hidden_local_group = FactoryBot.create(:local_group, name: 'Hidden Group')
    account.local_groupships.create!(local_group: local_group)
    account.local_groupships.create!(local_group: hidden_local_group).set(hide_membership: true)
    FactoryBot.create(:gathering, name: 'Listed Gathering', account: account)
    FactoryBot.create(:gathering, name: 'Unlisted Gathering', account: account, listed: false)
    FactoryBot.create(:gathering, name: 'Secret Gathering', account: account, privacy: 'secret')

    %w[activities local_groups gatherings].each do |list|
      get "/u/#{account.username}/#{list}", {}, XHR
      assert_equal 403, last_response.status
    end

    sign_in_with_rack(FactoryBot.create(:account))
    get "/u/#{account.username}/activities", {}, XHR
    assert_includes last_response.body, 'Shown Activity'
    refute_includes last_response.body, 'Hidden Activity'
    get "/u/#{account.username}/local_groups", {}, XHR
    assert_includes last_response.body, 'Shown Group'
    refute_includes last_response.body, 'Hidden Group'
    get "/u/#{account.username}/gatherings", {}, XHR
    assert_includes last_response.body, 'Listed Gathering'
    refute_includes last_response.body, 'Unlisted Gathering'
    refute_includes last_response.body, 'Secret Gathering'
  end

  test "an account's activities, local groups and gatherings follow its privacy, and a private profile's show only to it" do
    account = public_account(activities_privacy: 'Only me', local_groups_privacy: 'Only me', gatherings_privacy: 'Only me')
    account.activityships.create!(activity: FactoryBot.create(:activity, name: 'Shown Activity'))
    never_signed_in = FactoryBot.create(:account, activities_privacy: 'Public')
    assert never_signed_in.private?
    never_signed_in.activityships.create!(activity: FactoryBot.create(:activity, name: 'Private Activity'))

    sign_in_with_rack(FactoryBot.create(:account))
    %w[activities local_groups gatherings].each do |list|
      get "/u/#{account.username}/#{list}", {}, XHR
      assert_equal 403, last_response.status
    end
    get "/u/#{never_signed_in.username}/activities", {}, XHR
    assert_equal 403, last_response.status

    sign_in_with_rack(account)
    get "/u/#{account.username}/activities", {}, XHR
    assert_includes last_response.body, 'Shown Activity'
  end

  test 'someone follows another person, with email updates or without, and unfollows them' do
    covers_route 'POST /follow/:username'
    follower = FactoryBot.create(:account)
    followee = public_account
    sign_in_with_rack(follower)

    post "/follow/#{followee.username}", f: 'follow_and_subscribe'
    assert_equal "/u/#{followee.username}", URI(last_response.location).path
    follow = Follow.find_by(follower: follower, followee: followee)
    refute follow.unsubscribed

    post "/follow/#{followee.username}", { f: 'follow_without_subscribing' }, XHR
    assert last_response.ok?
    assert follow.reload.unsubscribed

    post "/follow/#{followee.username}", f: 'not_following'
    assert_nil Follow.find_by(follower: follower, followee: followee)
  end

  test "following someone changes only one's own follows, and needs signing in" do
    followee = public_account
    other = FactoryBot.create(:account)
    other_follow = Follow.create!(follower: other, followee: followee)

    post "/follow/#{followee.username}", f: 'follow_and_subscribe'
    assert_equal '/accounts/new', URI(last_response.location).path
    assert_equal [other_follow.id], followee.follows_as_followee.pluck(:id)

    sign_in_with_rack(FactoryBot.create(:account))
    post "/follow/#{followee.username}", f: 'not_following', follower_id: other.id
    assert other_follow.reload
  end

  test 'the follow button shows how one follows someone' do
    covers_route 'GET /follow/:username'
    follower = FactoryBot.create(:account)
    followee = public_account
    sign_in_with_rack(follower)

    get "/follow/#{followee.username}", {}, XHR
    assert last_response.ok?
    assert_includes last_response.body, "/follow/#{followee.username}?f=follow_and_subscribe"

    get "/follow/#{followee.username}"
    assert_equal "/u/#{followee.username}", URI(last_response.location).path
  end

  test 'someone stars and unstars a person they follow' do
    covers_route 'GET /follow/starred/:id'
    covers_route 'POST /follow/star/:id'
    covers_route 'POST /follow/unstar/:id'
    follower = FactoryBot.create(:account)
    follow = Follow.create!(follower: follower, followee: public_account)
    sign_in_with_rack(follower)

    get "/follow/starred/#{follow.id}", {}, XHR
    assert_includes last_response.body, "/follow/star/#{follow.id}"
    post "/follow/star/#{follow.id}"
    assert last_response.ok?
    assert follow.reload.starred
    get "/follow/starred/#{follow.id}", {}, XHR
    assert_includes last_response.body, "/follow/unstar/#{follow.id}"
    post "/follow/unstar/#{follow.id}"
    refute follow.reload.starred
  end

  test "someone can't star or see the star of another person's follow" do
    other = FactoryBot.create(:account)
    follow = Follow.create!(follower: other, followee: public_account)
    sign_in_with_rack(FactoryBot.create(:account))

    get "/follow/starred/#{follow.id}", {}, XHR
    assert_equal 404, last_response.status
    post "/follow/star/#{follow.id}"
    assert_equal 404, last_response.status
    refute follow.reload.starred

    follow.set(starred: true)
    post "/follow/unstar/#{follow.id}"
    assert_equal 404, last_response.status
    assert follow.reload.starred
  end

  test "disconnecting a provider disconnects only one's own, and a provider there isn't is not found" do
    account = FactoryBot.create(:account)
    other = FactoryBot.create(:account)
    [account, other].each do |a|
      a.provider_links.create!(provider: 'Google', provider_uid: "google-uid-#{a.id}", omniauth_hash: { 'uid' => "google-uid-#{a.id}" })
    end
    sign_in_with_rack(account)

    post '/accounts/disconnect/no_such_provider', account_id: other.id
    assert_equal 404, last_response.status
    post '/accounts/disconnect/google_oauth2', account_id: other.id
    assert_equal '/accounts/providers', URI(last_response.location).path
    assert_empty account.reload.provider_links
    assert_equal ['Google'], other.reload.provider_links.map(&:provider)
  end

  test "an old /accounts/:id URL redirects to the account by username, and one that names no account isn't found" do
    covers_route 'GET /accounts/:id/*'
    account = public_account
    get "/accounts/#{account.id}/organisations"
    assert_equal 307, last_response.status
    assert_equal "/u/#{account.username}/organisations", URI(last_response.location).path

    get "/accounts/#{BSON::ObjectId.new}/organisations"
    assert_equal 404, last_response.status
  end

  test "Bluesky's client metadata names the app's client and publishes only the public half of its key" do
    covers_route 'GET /atproto/oauth-client-metadata.json'
    key = OpenSSL::PKey::EC.generate('prime256v1')
    AtprotoKeyManager.stub(:current_private_key, key) do
      AtprotoKeyManager.stub(:current_jwk, AtprotoKeyManager.build_jwk(key)) do
        get '/atproto/oauth-client-metadata.json'
      end
    end
    assert_equal 'application/json', last_response.media_type
    metadata = JSON.parse(last_response.body)
    assert_equal AtprotoKeyManager.client_id, metadata['client_id']
    assert_equal [AtprotoKeyManager.redirect_uri], metadata['redirect_uris']
    jwk = metadata['jwks']['keys'].first
    assert_equal %w[x y], (jwk.keys & %w[d x y]).sort
  end

  test 'a sign in that fails comes back to the sign in page saying so' do
    covers_route 'GET /auth/failure'
    visit '/auth/failure?message=invalid_credentials'
    assert page.has_content?('There was a problem signing you in.')
    assert page.has_field?('Email')
  end
end
