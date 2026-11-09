require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class AccountsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def fill_signup_form(account)
    fill_in 'Full name', with: account.name
    fill_in 'Email', with: account.email
    fill_in 'Location', with: account.location
    click_button 'Sign up'
  end

  def assert_edit_redirect_with_param(param_name, param_value)
    assert page.has_current_path?(%r{/accounts/edit}, ignore_query: true),
           "Expected redirect to /accounts/edit, got #{page.current_path}"
    assert page.has_current_path?(/#{Regexp.escape("#{param_name}=#{param_value}")}/, url: true),
           "Expected URL to include #{param_name}=#{param_value}"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Basic Authentication Tests
  # ═══════════════════════════════════════════════════════════════════════════

  test 'signing up' do
    account = FactoryBot.build_stubbed(:account)
    visit '/accounts/new'
    fill_signup_form(account)
    assert page.has_content?('Welcome to Dandelion!')
  end

  test 'signing in' do
    account = FactoryBot.create(:account)
    visit '/accounts/sign_in'
    fill_in 'Email', with: account.email
    fill_in 'Password', with: account.password
    click_button 'Sign in'
    assert page.has_content?('Signed in')
    assert page.has_current_path?('/')
    assert_equal 1, account.reload.sign_ins.count
  end

  test 'password callback rejects GET' do
    account = FactoryBot.create(:account)

    get '/auth/account/callback', email: account.email, password: account.password

    assert last_response.redirect?, "expected a redirect to /auth/failure, got #{last_response.status}"
    location = URI(last_response.location)
    assert_equal '/auth/failure', location.path
    assert_includes Rack::Utils.parse_query(location.query)['message'], 'invalid_request'
    assert_equal 0, account.reload.sign_ins.count
  end

  test 'generated avatars take the initials of the first and last names' do
    assert_equal 'SR', GeneratedAvatar.initials('Stephen Reid')
    assert_equal 'JG', GeneratedAvatar.initials('Dr. Jane Mary Goodall')
    assert_equal 'M', GeneratedAvatar.initials('madonna')
    assert_equal 'ÉZ', GeneratedAvatar.initials('Émile Zola')
    assert_nil GeneratedAvatar.initials('Ольга Петрова')
    assert_nil GeneratedAvatar.initials(nil)
  end

  test 'accounts with no image fall back to their generated avatar' do
    account = FactoryBot.create(:account, name: 'Émile Zola')

    assert_equal '/avatar/v2/ÉZ.png', account.generated_avatar_path

    # Views escape the URL again with u, so Gravatar's fallback must come through that and one decode intact
    src = URI::Parser.new.escape(account.image_thumb_or_gravatar_url)
    assert_equal "#{ENV['BASE_URI']}/avatar/v2/%C3%89Z.png", URI.decode_www_form(URI(src).query).to_h['d']
  end

  test 'an image url uses the derivative another process stored while this one made it, dropping its own copy' do
    datastore = Dragonfly.app.datastore
    job = Dragonfly.app.fetch(Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg')))
    theirs = DragonflyJob.create!(signature: job.signature, uid: Dragonfly.app.store(File.binread('app/assets/images/test-event.jpg')))

    # The first lookup misses: the worker (warm_image_derivatives) stores theirs while this request makes its own
    find_by = DragonflyJob.method(:find_by)
    lookups = 0
    find_by_after_their_store = lambda do |*args|
      lookups += 1
      lookups == 1 ? nil : find_by.call(*args)
    end
    destroyed = []
    url = DragonflyJob.stub(:find_by, find_by_after_their_store) do
      datastore.stub(:destroy, ->(uid) { destroyed << uid }) { job.url }
    end

    assert_equal datastore.url_for(theirs.uid), url
    assert_equal 1, DragonflyJob.and(signature: job.signature).count
    assert_equal 1, destroyed.size
    refute_equal theirs.uid, destroyed.first
  end

  test 'generated avatars are PNGs, for initials of one or two Latin letters' do
    # ImageMagick, which draws them, isn't on CI's runner, so this checks the routes, not the drawing
    { '/avatar/v2.png' => nil, '/avatar/v2/SR.png' => 'SR', '/avatar/v2/%C3%89Z.png' => 'ÉZ' }.each do |path, initials|
      drawn = :not_drawn
      draw = lambda do |i = nil|
        drawn = i
        'png'
      end
      GeneratedAvatar.stub(:png, draw) { get path }
      assert last_response.ok?, "expected #{path} to be served, got #{last_response.status}"
      assert_equal 'image/png', last_response.media_type
      assert_equal initials.to_s, drawn.to_s
    end

    ['/avatar/v2/ABC.png', '/avatar/v2/12.png'].each do |path|
      get path
      assert last_response.not_found?, "expected #{path} to 404, got #{last_response.status}"
    end
  end

  test 'generated usernames take the lowest free number when the name is taken' do
    FactoryBot.create(:account, username: 'cool_sun')
    FactoryBot.create(:account, username: 'cool_sun_1')
    FactoryBot.create(:account, username: 'cool_sun_3')
    FactoryBot.create(:account, username: 'cool_sunrise')
    Haikunator.stub(:haikunate, 'cool-sun') do
      assert_equal 'cool_sun_2', Account.generate_username
      account = FactoryBot.create(:account)
      assert_equal 'cool_sun_2', account.username
      assert_equal 'cool_sun_4', Account.generate_username
    end
    Haikunator.stub(:haikunate, 'cool-moon') { assert_equal 'cool_moon', Account.generate_username }
  end

  test 'a generated password nobody is given is hashed at minimum cost, and one someone sets at full cost' do
    BCrypt::Engine.stub(:cost, 5) do
      unused = Account.create!(name: 'Unused Password', email: "unused@#{ENV['DOMAIN']}")
      assert_equal BCrypt::Engine::MIN_COST, BCrypt::Password.new(unused.crypted_password).cost

      unused.update_attributes!(password: 'a password someone chose')
      assert_equal 5, BCrypt::Password.new(unused.crypted_password).cost
      assert unused.password_matches?('a password someone chose')

      given = FactoryBot.create(:account, password: Account.generate_password)
      assert_equal 5, BCrypt::Password.new(given.crypted_password).cost
    end
  end

  test 'Bluesky link cards keep only http and https links' do
    account = FactoryBot.create(:account)
    card = lambda do |uri, thumb, n|
      { 'post' => { 'uri' => "at://did:plc:x/app.bsky.feed.post/#{n}", 'record' => { 'createdAt' => Time.now.iso8601 },
                    'embed' => { '$type' => 'app.bsky.embed.external#view',
                                 'external' => { 'uri' => uri, 'title' => 'Card', 'thumb' => thumb } } } }
    end
    posts = [
      card.call('javascript:alert(document.domain)', 'https://cdn.bsky.app/a.jpg', 1),
      card.call('https://example.com/post', 'javascript:alert(1)', 2)
    ]

    links = account.stub(:atproto_posts, posts) { account.atproto_links }

    assert_equal(['https://example.com/post'], links.map { |l| l['url'] })
    assert_nil links.first['image']
  end

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

  test 'unsubscribe link does not follow an account you do not already follow' do
    victim = FactoryBot.create(:account)
    attacker = FactoryBot.create(:account)
    sign_in_with_rack(victim)

    get "/u/#{attacker.username}/unsubscribe"

    assert last_response.redirect?
    assert_nil Follow.find_by(follower: victim, followee: attacker)
  end

  test 'network notifications reuse a notification cache created by a concurrent request' do
    account = FactoryBot.create(:account)
    AccountNotificationCache.create!(account: account, account_ids: [account.id], expires_at: 1.day.from_now)

    # the has_one read misses the cache another request has just created, so the insert hits the unique index
    duplicate_key = -> { raise Mongo::Error::OperationFailure.new('E11000 duplicate key error', nil, code: 11_000) }
    notifications = account.stub(:account_notification_cache, nil) do
      account.stub(:create_account_notification_cache, duplicate_key) do
        account.network_notifications
      end
    end
    assert_includes notifications.selector.to_s, account.id.to_s
  end

  test 'network notifications re-raise other operation failures' do
    account = FactoryBot.create(:account)

    not_primary = -> { raise Mongo::Error::OperationFailure.new('not primary', nil, code: 10_107) }
    account.stub(:account_notification_cache, nil) do
      account.stub(:create_account_notification_cache, not_primary) do
        assert_raises(Mongo::Error::OperationFailure) { account.network_notifications }
      end
    end
  end

  test "leaving an organisation, activity, local group or gathering, or unfollowing someone, takes it off the notification cache's ids at once" do
    organisation = FactoryBot.create(:organisation)
    activity = FactoryBot.create(:activity, organisation: organisation, privacy: 'open')
    local_group = FactoryBot.create(:local_group, organisation: organisation)
    gathering = FactoryBot.create(:gathering, account: FactoryBot.create(:account))
    followee = FactoryBot.create(:account)

    # Each joins, then leaves as its controller does: found through the account, then destroyed
    {
      organisations_ids: [organisation, ->(a) { a.organisationships.create!(organisation: organisation, skip_welcome: true) }, ->(a) { a.organisationships.find_by(organisation: organisation) }],
      activity_ids: [activity, ->(a) { a.activityships.create!(activity: activity) }, ->(a) { a.activityships.find_by(activity: activity) }],
      local_group_ids: [local_group, ->(a) { a.local_groupships.create!(local_group: local_group) }, ->(a) { a.local_groupships.find_by(local_group: local_group) }],
      gathering_ids: [gathering, ->(a) { gathering.memberships.create!(account: a) }, ->(a) { a.memberships.find_by(gathering: gathering) }],
      account_ids: [followee, ->(a) { a.follows_as_follower.create!(followee: followee) }, ->(a) { a.follows_as_follower.find_by(followee: followee) }]
    }.each do |field, (joined, join, find)|
      account = FactoryBot.create(:account)
      account.create_account_notification_cache
      join.(account)
      assert_includes AccountNotificationCache.find_by(account_id: account.id).send(field), joined.id, "#{field} after joining"

      find.(account).destroy
      assert_not_includes AccountNotificationCache.find_by(account_id: account.id).send(field), joined.id, "#{field} after leaving"
    end
  end

  test 'unsubscribe link unsubscribes from an account you follow' do
    account = FactoryBot.create(:account)
    followee = FactoryBot.create(:account)
    follow = Follow.create!(follower: account, followee: followee)
    sign_in_with_rack(account)

    get "/u/#{followee.username}/unsubscribe"

    assert follow.reload.unsubscribed
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

  test 'editing profile' do
    account = FactoryBot.create(:account)
    sign_in(account)
    click_link account.name
    click_link 'Edit profile'
    fill_in 'Full name', with: (name = FactoryBot.build_stubbed(:account).name)
    click_button 'Save profile'
    assert page.has_content?('Your account was updated successfully')
    assert page.has_content?(name)
  end

  # Stands in for the Places library, so places.js can be tested without a Google Maps key. places.js only asks
  # for the library as someone types, so this can replace importLibrary once the page has loaded. The setter
  # ignores the real API, which assigns its own importLibrary when it finishes loading
  FAKE_PLACES_JS = <<~JS.freeze
    const importLibrary = async function (name) {
      if (name !== 'places') throw new Error('Not faked: ' + name)
      return {
        AutocompleteSessionToken: class {},
        AutocompleteSuggestion: {
          fetchAutocompleteSuggestions: async function (request) {
            const places = ['Stockholm, Sweden', 'Stockport, UK'].filter(place => place.toLowerCase().startsWith(request.input.toLowerCase()))
            return { suggestions: places.map(place => ({ placePrediction: { text: { toString: () => place } } })) }
          }
        }
      }
    }
    Object.defineProperty(google.maps, 'importLibrary', { get: () => importLibrary, set: () => {} })
  JS

  test 'suggesting places for a location' do
    account = FactoryBot.create(:account)
    sign_in(account)
    visit '/accounts/edit'
    execute_script FAKE_PLACES_JS

    # Typed rather than filled in, since fill_in blurs the field, which cancels jQuery UI's search
    location = find_field('Location')
    location.set('')
    location.send_keys('Stock')
    assert page.has_css?('.places-autocomplete li', text: 'Stockport, UK')
    # Enter with the menu open and nothing highlighted closes the menu rather than submitting the form
    location.send_keys(:enter)
    assert page.has_no_css?('.places-autocomplete li', visible: true)
    assert page.has_no_content?('Your account was updated successfully')

    location.send_keys('h')
    find('.places-autocomplete li', text: 'Stockholm, Sweden').click
    assert_equal 'Stockholm, Sweden', location.value
    click_button 'Save profile'
    assert page.has_content?('Your account was updated successfully')
    assert_equal 'Stockholm, Sweden', account.reload.location
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # New Account Creation with Context
  # ═══════════════════════════════════════════════════════════════════════════

  test 'signing up after visiting referral link returns to organisation creation' do
    referrer = FactoryBot.create(:account, username: 'refsignup', name: 'Signup Referrer', has_signed_in: true)
    account = FactoryBot.build_stubbed(:account)
    organisation = FactoryBot.build_stubbed(:organisation)

    visit "/invite/#{referrer.username}"
    fill_signup_form(account)

    assert page.has_current_path?(%r{/o/new}, ignore_query: true)

    fill_in 'Organisation name', with: organisation.name
    fill_in 'URL', with: organisation.slug
    click_button 'Save and continue'

    saved_organisation = Organisation.find_by(slug: organisation.slug)
    assert_equal referrer.id, saved_organisation.referrer_id
  end

  test 'email sign in token stays on the linked event instead of a previous return_to' do
    create_event(as: :event1)
    create_event(as: :event2)
    account = FactoryBot.create(:account)

    visit "/e/#{@event1.slug}"
    account.generate_link_token!
    visit "/e/#{@event2.slug}?link_token=#{account.link_token}"

    assert page.has_current_path?(%r{/e/#{@event2.slug}}, ignore_query: true),
           "Expected to stay on #{@event2.slug}, got #{page.current_path}"
    assert page.has_no_current_path?(/#{@event1.slug}/, ignore_query: true)
  end

  test 'sign in token on homepage still honours return_to from an event page' do
    create_event
    account = FactoryBot.create(:account)

    visit "/e/#{@event.slug}"
    account.generate_link_token!
    visit "/?link_token=#{account.link_token}"

    assert page.has_current_path?(%r{/e/#{@event.slug}}, ignore_query: true),
           "Expected to return to #{@event.slug}, got #{page.current_path}"
  end

  test 'return_to is cleared after signup redirect' do
    referrer = FactoryBot.create(:account, username: 'refclear', has_signed_in: true)
    account = FactoryBot.build_stubbed(:account)

    visit "/invite/#{referrer.username}"
    fill_signup_form(account)
    assert page.has_current_path?(%r{/o/new}, ignore_query: true)

    visit '/accounts/sign_out'
    account2 = FactoryBot.build_stubbed(:account)
    visit '/accounts/new'
    fill_signup_form(account2)

    assert page.has_current_path?(%r{/accounts/edit}, ignore_query: true)
    assert page.has_no_current_path?(%r{/o/new}, ignore_query: true)
  end

  test 'signing up with organisation_id' do
    create_organisation
    account = FactoryBot.build_stubbed(:account)

    visit "/accounts/new?organisation_id=#{@organisation.id}"
    fill_signup_form(account)

    assert_edit_redirect_with_param('organisation_id', @organisation.id)
    created_account = Account.find_by(email: account.email.downcase)
    assert_associated(@organisation, created_account, :organisationships)
  end

  test 'signing up with activity_id' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'open')
    account = FactoryBot.build_stubbed(:account)

    visit "/accounts/new?activity_id=#{activity.id}"
    fill_signup_form(account)

    assert_edit_redirect_with_param('activity_id', activity.id)
    created_account = Account.find_by(email: account.email.downcase)
    assert_associated(activity, created_account, :activityships)
    assert_associated(@organisation, created_account, :organisationships)
  end

  test 'signing up with local_group_id' do
    create_organisation
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    account = FactoryBot.build_stubbed(:account)

    visit "/accounts/new?local_group_id=#{local_group.id}"
    fill_signup_form(account)

    assert_edit_redirect_with_param('local_group_id', local_group.id)
    created_account = Account.find_by(email: account.email.downcase)
    assert_associated(local_group, created_account, :local_groupships)
    assert_associated(@organisation, created_account, :organisationships)
  end

  test 'signing up with event_id' do
    create_full_event_hierarchy
    account = FactoryBot.build_stubbed(:account)

    visit "/accounts/new?event_id=#{@event.id}"
    fill_signup_form(account)

    assert_edit_redirect_with_param('event_id', @event.id)
    created_account = Account.find_by(email: account.email.downcase)
    assert_associated(@organisation, created_account, :organisationships)
    assert_associated(@activity, created_account, :activityships)
    assert_associated(@local_group, created_account, :local_groupships)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Existing Account Handling (Signup with existing email)
  # ═══════════════════════════════════════════════════════════════════════════

  test 'existing account without context' do
    existing_account = FactoryBot.create(:account)

    visit '/accounts/new'
    fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

    assert page.has_content?("There's already an account registered under that email address")
    assert page.has_current_path?('/accounts/sign_in', ignore_query: true)
  end

  test 'existing account created by a concurrent signup' do
    # created first, as listing the indexes of a collection that doesn't exist yet raises
    existing_account = FactoryBot.create(:account)
    # the race only reaches the unique index, which the test database may not have
    Account.collection.indexes.create_one({ email: 1 }, unique: true) unless Account.collection.indexes.any? { |index| index['unique'] && index['key'] == { 'email' => 1 } }

    # the other request inserts the account after this one's uniqueness check, so the insert hits the unique index
    uniqueness = Account.validators_on(:email).find { |validator| validator.is_a?(Mongoid::Validatable::UniquenessValidator) }
    uniqueness.stub(:validate_each, nil) do
      visit '/accounts/new'
      fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

      assert page.has_content?("There's already an account registered under that email address")
      assert page.has_current_path?('/accounts/sign_in', ignore_query: true)
    end
  end

  test 'existing account with organisation_id' do
    create_organisation
    existing_account = FactoryBot.create(:account)

    visit "/accounts/new?organisation_id=#{@organisation.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(@organisation, existing_account, :organisationships)
  end

  test 'existing account with activity_id' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'open')
    existing_account = FactoryBot.create(:account)

    visit "/accounts/new?activity_id=#{activity.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(activity, existing_account, :activityships)
    assert_associated(@organisation, existing_account, :organisationships)
  end

  test 'signing up with the activity_id of a closed activity does not join it' do
    covers 'organisations/application-only-activities@7b2afe'
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'closed')
    account = FactoryBot.build_stubbed(:account)

    visit "/accounts/new?activity_id=#{activity.id}"
    fill_signup_form(account)

    created_account = Account.find_by(email: account.email.downcase)
    assert_nil activity.activityships.find_by(account: created_account)
  end

  test 'existing account with local_group_id' do
    create_organisation
    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    existing_account = FactoryBot.create(:account)

    visit "/accounts/new?local_group_id=#{local_group.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(local_group, existing_account, :local_groupships)
    assert_associated(@organisation, existing_account, :organisationships)
  end

  test 'existing account with event_id' do
    create_full_event_hierarchy
    existing_account = FactoryBot.create(:account)

    visit "/accounts/new?event_id=#{@event.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(@organisation, existing_account, :organisationships)
    assert_associated(@activity, existing_account, :activityships)
    assert_associated(@local_group, existing_account, :local_groupships)
  end

  test 'existing account with event_id resubscribes unsubscribed accounts' do
    create_full_event_hierarchy

    # Create an existing account that's unsubscribed from org, activity, and local_group
    existing_account = FactoryBot.create(:account)
    @organisation.organisationships.find_or_create_by(account: existing_account).set_unsubscribed!(true)
    @activity.activityships.find_or_create_by(account: existing_account).set(unsubscribed: true)
    @local_group.local_groupships.find_or_create_by(account: existing_account).set(unsubscribed: true)

    # Sign up with event_id (which should resubscribe via associate_with_event!)
    visit "/accounts/new?event_id=#{@event.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

    assert page.has_content?("OK, you're on the list!")

    assert_equal false, @organisation.organisationships.find_by(account: existing_account).unsubscribed
    assert_equal false, @activity.activityships.find_by(account: existing_account).unsubscribed
    assert_equal false, @local_group.local_groupships.find_by(account: existing_account).unsubscribed
  end

  test 'merging accounts transfers organisationships and rebuilds caches' do
    survivor = FactoryBot.create(:account)
    victim = FactoryBot.create(:account)
    org_a = FactoryBot.create(:organisation)
    org_b = FactoryBot.create(:organisation)

    victim_organisationship = victim.organisationships.create!(organisation: org_a)
    victim_organisationship.set(admin: true)
    survivor_organisationship = survivor.organisationships.create!(organisation: org_a)
    victim.organisationships.create!(organisation: org_b)

    survivor.merge(victim)
    survivor.reload
    surviving_organisationship = survivor.organisationships.find_by(organisation: org_a)

    assert_nil Account.find(victim.id)
    assert_equal 1, survivor.organisationships.and(organisation: org_a).count
    assert_equal 1, survivor.organisationships.and(organisation: org_b).count
    assert_equal survivor_organisationship.id, surviving_organisationship.id
    assert surviving_organisationship.admin
    cached = survivor.organisation_ids_cache.map(&:to_s)
    assert_includes cached, org_a.id.to_s
    assert_includes cached, org_b.id.to_s
    assert_includes survivor.subscribed_organisation_ids_cache.map(&:to_s), org_b.id.to_s
  end

  test 'merging accounts preserves creditings, stripe connect, and monthly donation from the victim organisationship' do
    survivor = FactoryBot.create(:account)
    victim = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, currency: 'GBP')
    stripe_connect_json = { 'stripe_user_id' => 'acct_victim' }.to_json
    stripe_account_json = { 'display_name' => 'Victim Connect' }.to_json

    survivor_organisationship = survivor.organisationships.create!(organisation: org)
    survivor_organisationship.creditings.create!(account: survivor, amount: 10, currency: 'GBP')
    victim_organisationship = victim.organisationships.create!(organisation: org)
    victim_organisationship.set(
      stripe_connect_json: stripe_connect_json,
      stripe_account_json: stripe_account_json,
      monthly_donation_method: 'GoCardless',
      monthly_donation_amount: 15.0,
      monthly_donation_currency: 'GBP'
    )
    victim_crediting = victim_organisationship.creditings.create!(account: victim, amount: 40, currency: 'GBP')

    survivor.merge(victim)
    surviving_organisationship = survivor.reload.organisationships.find_by(organisation: org)

    assert_equal survivor_organisationship.id, surviving_organisationship.id
    assert_equal 1, survivor.organisationships.and(organisation: org).count
    assert_equal [10, 40], surviving_organisationship.creditings.order('amount asc').pluck(:amount)
    assert_equal victim_crediting.id, surviving_organisationship.creditings.find(victim_crediting.id).id
    assert_equal stripe_connect_json, surviving_organisationship.stripe_connect_json
    assert_equal stripe_account_json, surviving_organisationship.stripe_account_json
    assert_equal 'GoCardless', surviving_organisationship.monthly_donation_method
    assert_equal 15.0, surviving_organisationship.monthly_donation_amount
    assert_equal 'GBP', surviving_organisationship.monthly_donation_currency
    assert_equal Money.new(5000, 'GBP'), surviving_organisationship.credit_granted
  end

  test 'merging accounts that share an organisation, gathering and followee keeps one of each' do
    # the unique indexes behind the uniqueness validations, as in production, which the test database may not have
    [[Organisationship, { organisation_id: 1, account_id: 1 }], [Membership, { gathering_id: 1, account_id: 1 }],
     [Activityship, { activity_id: 1, account_id: 1 }], [Follow, { follower_id: 1, followee_id: 1 }]].each do |model, key|
      model.collection.indexes.create_one(key, unique: true)
    end
    survivor = FactoryBot.create(:account)
    victim = FactoryBot.create(:account)
    followee = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation)
    activity = FactoryBot.create(:activity, organisation: organisation)
    gathering = FactoryBot.create(:gathering, account: FactoryBot.create(:account))
    team = gathering.teams.create!(name: 'Kitchen', account: gathering.account)

    survivor_organisationship = survivor.organisationships.create!(organisation: organisation)
    victim.organisationships.create!(organisation: organisation).set(admin: true)
    survivor_activityship = activity.activityships.create!(account: survivor)
    activity.activityships.create!(account: victim, admin: true, receive_feedback: true)
    survivor_membership = gathering.memberships.create!(account: survivor)
    survivor_membership.set(paid: 20)
    victim_membership = gathering.memberships.create!(account: victim)
    victim_membership.set(paid: 30, admin: true)
    victim_teamship = team.teamships.create!(account: victim, gathering: gathering)
    Follow.create!(follower: survivor, followee: followee)
    Follow.create!(follower: victim, followee: followee)

    survivor.merge(victim)

    assert_nil Account.find(victim.id)
    assert_equal [survivor_organisationship.id], organisation.organisationships.and(:account_id.in => [survivor.id, victim.id]).pluck(:id)
    assert survivor_organisationship.reload.admin
    assert_equal [survivor_activityship.id], activity.activityships.and(:account_id.in => [survivor.id, victim.id]).pluck(:id)
    assert survivor_activityship.reload.admin
    assert survivor_activityship.receive_feedback
    assert_equal [survivor_membership.id], gathering.memberships.and(:account_id.in => [survivor.id, victim.id]).pluck(:id)
    assert survivor_membership.reload.admin
    assert_equal 50, survivor_membership.paid
    victim_teamship = Teamship.find(victim_teamship.id)
    assert_equal [survivor.id, survivor_membership.id], [victim_teamship.account_id, victim_teamship.membership_id]
    assert_equal [survivor.id], Follow.and(followee: followee).pluck(:follower_id)
  end

  test 'merging accounts that both applied to a gathering keeps the accepted application and its membership' do
    Mapplication.collection.indexes.create_one({ gathering_id: 1, account_id: 1 }, unique: true)
    survivor = FactoryBot.create(:account)
    victim = FactoryBot.create(:account)
    voter = FactoryBot.create(:account)
    gathering = FactoryBot.create(:gathering, account: FactoryBot.create(:account))

    survivor_mapplication = gathering.mapplications.create!(account: survivor, status: 'pending')
    victim_mapplication = gathering.mapplications.create!(account: victim, status: 'pending')
    victim_mapplication.accept
    gathering.memberships.create!(account: voter)
    verdict = victim_mapplication.verdicts.create!(account: voter, type: 'supporter')

    survivor.merge(victim)

    assert_equal [survivor_mapplication.id], gathering.mapplications.and(:account_id.in => [survivor.id, victim.id]).pluck(:id)
    assert_equal 'accepted', survivor_mapplication.reload.status
    membership = gathering.memberships.find_by(account: survivor)
    assert_equal survivor_mapplication.id, membership.mapplication_id
    assert_equal survivor_mapplication.id, Verdict.find(verdict.id).mapplication_id
  end

  test 'merging accounts keeps the survivor stripe connect when both memberships have it' do
    survivor = FactoryBot.create(:account)
    victim = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation)
    survivor_stripe = { 'stripe_user_id' => 'acct_survivor' }.to_json
    victim_stripe = { 'stripe_user_id' => 'acct_victim' }.to_json

    survivor_organisationship = survivor.organisationships.create!(organisation: org)
    survivor_organisationship.set(stripe_connect_json: survivor_stripe)
    victim_organisationship = victim.organisationships.create!(organisation: org)
    victim_organisationship.set(stripe_connect_json: victim_stripe)

    survivor.merge(victim)
    surviving_organisationship = survivor.reload.organisationships.find_by(organisation: org)

    assert_equal survivor_organisationship.id, surviving_organisationship.id
    assert_equal survivor_stripe, surviving_organisationship.stripe_connect_json
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

  # Accounts at these coordinates in the organisation, put there directly, so they've no stored hexagon (map_hex), like
  # accounts geocoded before they stored one. Each has its own email and username, which have unique indexes
  def insert_map_accounts(coordinates, organisation)
    Account.collection.insert_many(coordinates.map do |c|
      token = SecureRandom.hex(8)
      { coordinates: c, organisation_ids_public_cache: [organisation.id], email: "map-#{token}@example.com", username: "map-#{token}" }
    end)
  end

  test 'maps of many accounts show how many are in each hexagon, whoever is looking' do
    organisation = FactoryBot.create(:organisation)
    hackney = [-0.0553, 51.545]
    centre_lng, centre_lat = MapHexagons.point(MapHexagons.hex(*hackney, MapHexagons::SIZE), MapHexagons::SIZE)
    far_lng, far_lat = MapHexagons.point(MapHexagons.hex(-3.12345, 50.98765, MapHexagons::SIZE), MapHexagons::SIZE)
    [[hackney, 'Public'], [[centre_lng, centre_lat], 'Only me'], [[-3.12345, 50.98765], 'Only me']].each do |coordinates, privacy|
      account = FactoryBot.create(:account, location_privacy: privacy)
      # Saved, so it stores its hexagon (map_hex), which the map counts by
      account.update_attribute(:coordinates, coordinates)
      account.set(organisation_ids_public_cache: [organisation.id])
      assert account.reload.map_hex
    end
    map_cells = lambda do |west, south, east, north|
      get '/map.json', organisation_id: organisation.id, west: west, south: south, east: east, north: north
      response = JSON.parse(last_response.body)
      assert(response['cells'].all? { |cell| cell['corners'].length == 6 })
      response['cells'].map { |cell| [cell['lat'], cell['lng'], cell['count']] }.sort
    end

    clear_cookies
    # Two accounts share a hexagon, so they're one cell: no account's own place or id is sent
    assert_equal [[centre_lat, centre_lng, 2]], map_cells.call(-0.2, 51.45, 0.1, 51.65)
    refute_includes last_response.body, '"id"'
    assert_equal [[far_lat, far_lng, 1]], map_cells.call(-3.2, 50.9, -3.0, 51.05)

    # Any box in a hexagon finds the same, however small, so narrowing boxes can't find where an account is in it
    assert((centre_lng - hackney[0]).abs > 0.001 || (centre_lat - hackney[1]).abs > 0.001)
    assert_equal [[centre_lat, centre_lng, 2]], map_cells.call(hackney[0] - 0.001, hackney[1] - 0.001, hackney[0] + 0.001, hackney[1] + 0.001)
    assert_equal [[centre_lat, centre_lng, 2]], map_cells.call(centre_lng - 0.001, centre_lat - 0.001, centre_lng + 0.001, centre_lat + 0.001)
    assert_equal [[centre_lat, centre_lng, 2]], map_cells.call(centre_lng - 0.004, centre_lat - 0.0001, centre_lng + 0.0002, centre_lat + 0.003)
    # and a box clear of it finds nothing
    assert_equal [], map_cells.call(centre_lng + 0.05, centre_lat, centre_lng + 0.06, centre_lat + 0.01)

    account = Account.find_by(location_privacy: 'Public')
    env 'rack.session', { 'account_id' => account.id.to_s, 'session_token' => account.session_token! }
    assert_equal [[centre_lat, centre_lng, 2]], map_cells.call(centre_lng - 0.001, centre_lat - 0.001, centre_lng + 0.001, centre_lat + 0.001)
  end

  test 'a map with more occupied hexagons than it can show uses bigger ones, still counting everyone' do
    organisation = FactoryBot.create(:organisation)
    # A tall, narrow map, with one account in each of MAP_POINTS_LIMIT + 1 rows of hexagons, up the meridian. Put there
    # directly, so they've no stored hexagon (map_hex), like accounts geocoded before they stored one, and are counted
    # from their coordinates
    rows = (0..MAP_POINTS_LIMIT).map { |i| [0.0001, MapHexagons.mercator_lat((i + 0.1) * 1.5 * MapHexagons::SIZE)] }
    insert_map_accounts(rows, organisation)
    width = Math.sqrt(3) * MapHexagons::SIZE

    get '/map.json', organisation_id: organisation.id, west: -width * 4, south: -0.01, east: width * 4, north: rows.last[1] + 0.05
    cells = JSON.parse(last_response.body)['cells']
    assert_operator cells.length, :<=, MAP_POINTS_LIMIT
    assert_equal(MAP_POINTS_LIMIT + 1, cells.sum { |cell| cell['count'] })
    # The hexagons are twice as wide as a map that narrow starts with
    assert_in_delta 2 * width, (cells.first['corners'][0][1] - cells.first['corners'][3][1]).abs, 0.000002
  end

  test 'maps have hexagons about the same size on screen at every zoom' do
    organisation = FactoryBot.create(:organisation)
    insert_map_accounts([[-0.0553, 51.545]], organisation)
    hexagon_width = lambda do |map_width, pixels|
      get '/map.json', organisation_id: organisation.id, west: -0.0553 - (map_width / 2.0), south: 51.4, east: -0.0553 + (map_width / 2.0), north: 51.7, width: pixels
      corners = JSON.parse(last_response.body)['cells'].first['corners']
      (corners[0][1] - corners[3][1]).abs
    end

    # Never smaller than MapHexagons::SIZE, and otherwise MapHexagons::PIXELS to twice that wide on the map
    assert_in_delta Math.sqrt(3) * MapHexagons::SIZE, hexagon_width.call(0.1, 1000), 0.000002
    [[1.0, 1000], [4.0, 1000], [30.0, 1000], [30.0, 375]].each do |map_width, pixels|
      on_screen = hexagon_width.call(map_width, pixels) / map_width * pixels
      assert_operator on_screen, :>=, MapHexagons::PIXELS
      assert_operator on_screen, :<, 2 * MapHexagons::PIXELS
    end
  end

  test 'a zoomed out map starts with bigger hexagons, still counting everyone' do
    organisation = FactoryBot.create(:organisation)
    already = Account.and(organisation_ids_public_cache: organisation.id, :coordinates.ne => nil).count
    # Including some near the edges of the map, in hexagons whose centres are beyond them
    coordinates = [[-0.0553, 51.545], [-3.12345, 50.98765], [13.4, 52.52], [-74.0, 40.7], [175, 0], [0, 77]]
    insert_map_accounts(coordinates, organisation)

    get '/map.json', organisation_id: organisation.id, west: -180, south: -78, east: 180, north: 78
    cells = JSON.parse(last_response.body)['cells']
    assert_equal(already + coordinates.length, cells.sum { |cell| cell['count'] })
    # Hexagons a few degrees across, not a couple of kilometres
    assert_operator (cells.first['corners'][0][1] - cells.first['corners'][3][1]).abs, :>, 100 * Math.sqrt(3) * MapHexagons::SIZE
  end

  test 'zooming out keeps the accounts in a hexagon together, so it tells no more than zooming in' do
    organisation = FactoryBot.create(:organisation)
    # Two accounts in one small hexagon, near its edge, where bigger hexagons' edges could pass between them
    coordinates = [[0.1039, 0.0], [0.104, 0.0]]
    assert_equal(*coordinates.map { |c| MapHexagons.hex(*c, MapHexagons::SIZE) })
    insert_map_accounts(coordinates, organisation)

    get '/map.json', organisation_id: organisation.id, west: -2, south: -1, east: 2, north: 1
    cells = JSON.parse(last_response.body)['cells']
    assert_equal([2], cells.map { |cell| cell['count'] })
    # in a hexagon bigger than the smallest
    assert_operator (cells.first['corners'][0][1] - cells.first['corners'][3][1]).abs, :>, Math.sqrt(3) * MapHexagons::SIZE * 1.5
  end

  test 'there is no map of every account, only of an organisation, activity or local group' do
    get '/map.json', west: -4, south: 50, east: -3, north: 51
    assert_equal 404, last_response.status
    get '/map'
    assert_equal 404, last_response.status
  end

  test 'maps that show each account show it at the centre of its hexagon' do
    account = FactoryBot.create(:account)
    account.set(coordinates: [-0.0553, 51.545])
    hex = MapHexagons.hex(*account.coordinates, MapHexagons::SIZE)
    centre = MapHexagons.point(hex, MapHexagons::SIZE)
    assert_operator Math.hypot(centre[0] + 0.0553, MapHexagons.mercator_y(centre[1]) - MapHexagons.mercator_y(51.545)), :<=, MapHexagons::SIZE
    assert_equal hex, MapHexagons.hex(*centre, MapHexagons::SIZE)
    # map_point_lat_lng is a helper, which needs an app to call it on
    assert_equal centre.reverse, Dandelion::App.new!.map_point_lat_lng(account)
  end

  test 'an account stores the map hexagon it is in, and changes it when its coordinates change' do
    account = FactoryBot.create(:account)
    account.update_attribute(:coordinates, [-0.0553, 51.545])
    assert_equal MapHexagons.hex(-0.0553, 51.545, MapHexagons::SIZE).join(','), account.reload.map_hex
    account.update_attribute(:coordinates, [-3.12345, 50.98765])
    assert_equal MapHexagons.hex(-3.12345, 50.98765, MapHexagons::SIZE).join(','), account.reload.map_hex
    account.update_attribute(:coordinates, nil)
    assert_nil account.reload.map_hex
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

  # ═══════════════════════════════════════════════════════════════════════════
  # Sign-In with Ethereum (EIP-4361)
  # ═══════════════════════════════════════════════════════════════════════════

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

  test 'signup checks recaptcha when no skip secret is configured' do
    later = FactoryBot.build_stubbed(:account)
    verify_calls = with_recaptcha(skip_secret: nil) { post_new_account(later) }

    assert_equal 1, verify_calls.length
    assert_nil Account.find_by(email: later.email.downcase)
  end

  test 'signup checks recaptcha when the skip secret is wrong' do
    later = FactoryBot.build_stubbed(:account)
    verify_calls = with_recaptcha(skip_secret: 'right-secret') { post_new_account(later, recaptcha_skip_secret: 'wrong-secret') }

    assert_equal 1, verify_calls.length
    assert_nil Account.find_by(email: later.email.downcase)
  end

  test 'signup skips recaptcha with the right skip secret' do
    later = FactoryBot.build_stubbed(:account)
    verify_calls = with_recaptcha(skip_secret: 'right-secret') { post_new_account(later, recaptcha_skip_secret: 'right-secret') }

    assert_empty verify_calls
    assert Account.find_by(email: later.email.downcase)
  end

  private

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

  # Configures recaptcha with a verifier that always fails, and returns the verify calls made
  def with_recaptcha(skip_secret:, &)
    env = { 'RECAPTCHA_SECRET_KEY' => 'recaptcha-secret', 'RECAPTCHA_VERIFY_URL' => 'https://recaptcha.test/verify', 'RECAPTCHA_SKIP_SECRET' => skip_secret }
    previous = env.keys.to_h { |key| [key, ENV[key]] }
    env.each { |key, value| ENV[key] = value }

    # Real connections (Mailgun uses Faraday too), with only posts to the verify URL intercepted
    verify_url = env['RECAPTCHA_VERIFY_URL']
    verify_calls = []
    verify_response = api_object(body: { success: false }.to_json)
    faraday_new = Faraday.method(:new)
    stubbed_new = lambda do |*args, **kwargs, &block|
      connection = faraday_new.call(*args, **kwargs, &block)
      connection.define_singleton_method(:post) do |url = nil, body = nil, headers = nil, &post_block|
        return super(url, body, headers, &post_block) unless url == verify_url

        verify_calls << [url, body]
        verify_response
      end
      connection
    end
    Faraday.stub(:new, stubbed_new, &)
    verify_calls
  ensure
    previous.each { |key, value| ENV[key] = value }
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

  def post_new_account(account, extra = {})
    post '/accounts/new', {
      account: { name: account.name, email: account.email, location: account.location },
      recaptcha_skip_secret: ENV['RECAPTCHA_SKIP_SECRET']
    }.merge(extra)
  end
end
