require_relative '../test_config'

# Signing up, profiles, avatars, notifications, signing up from an organisation, activity, local group or event, merging accounts and maps of accounts
class AccountsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

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
    assert_equal 'SR', Account.avatar_initials('Stephen Reid')
    assert_equal 'JG', Account.avatar_initials('Dr. Jane Mary Goodall')
    assert_equal 'M', Account.avatar_initials('madonna')
    assert_equal 'ÉZ', Account.avatar_initials('Émile Zola')
    assert_nil Account.avatar_initials('Ольга Петрова')
    assert_nil Account.avatar_initials(nil)
  end

  test 'accounts with no image fall back to their generated avatar' do
    account = FactoryBot.create(:account, name: 'Émile Zola')

    assert_equal '/avatar/v2/ÉZ.png', account.generated_avatar_path

    # Views escape the URL again with u, so Gravatar's fallback must come through that and one decode intact
    src = URI::Parser.new.escape(account.image_thumb_or_gravatar_url)
    assert_equal "#{ENV['BASE_URI']}/avatar/v2/%C3%89Z.png", URI.decode_www_form(URI(src).query).to_h['d']
  end

  test 'an image url uses the derivative another process stored while this one made it, dropping its own copy' do
    covers_route 'GET /notifications'
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
    covers_route 'GET /avatar/v2'
    covers_route 'GET /avatar/v2/:initials'
    # ImageMagick, which draws them, isn't on CI's runner, so this checks the routes, not the drawing
    { '/avatar/v2.png' => nil, '/avatar/v2/SR.png' => 'SR', '/avatar/v2/%C3%89Z.png' => 'ÉZ' }.each do |path, initials|
      drawn = :not_drawn
      draw = lambda do |i = nil|
        drawn = i
        'png'
      end
      Account.stub(:avatar_png, draw) { get path }
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

  test 'unsubscribe link does not follow an account you do not already follow' do
    covers_route 'GET /u/:username/unsubscribe'
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
    covers_route 'GET /accounts/privacyable/:p'
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
    covers_route 'GET /accounts/sign_out'
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
    covers_route 'GET /accounts/new'
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

  test 'maps of many accounts show how many are in each hexagon, whoever is looking' do
    covers_route 'GET /map'
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

  test 'signup checks recaptcha when no skip secret is configured' do
    covers_route 'POST /accounts/new'
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

  def assert_edit_redirect_with_param(param_name, param_value)
    assert page.has_current_path?(%r{/accounts/edit}, ignore_query: true),
           "Expected redirect to /accounts/edit, got #{page.current_path}"
    assert page.has_current_path?(/#{Regexp.escape("#{param_name}=#{param_value}")}/, url: true),
           "Expected URL to include #{param_name}=#{param_value}"
  end

  # Accounts at these coordinates in the organisation, put there directly, so they've no stored hexagon (map_hex), like
  # accounts geocoded before they stored one. Each has its own email and username, which have unique indexes
  def insert_map_accounts(coordinates, organisation)
    Account.collection.insert_many(coordinates.map do |c|
      token = SecureRandom.hex(8)
      { coordinates: c, organisation_ids_public_cache: [organisation.id], email: "map-#{token}@example.com", username: "map-#{token}" }
    end)
  end

  # Configures recaptcha with a verifier that always fails, and returns the verify calls made
  def with_recaptcha(skip_secret:, &block)
    env = { 'RECAPTCHA_SECRET_KEY' => 'recaptcha-secret', 'RECAPTCHA_VERIFY_URL' => 'https://recaptcha.test/verify', 'RECAPTCHA_SKIP_SECRET' => skip_secret }

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
    with_env(env) { Faraday.stub(:new, stubbed_new, &block) }
    verify_calls
  end
end
