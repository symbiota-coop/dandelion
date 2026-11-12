require_relative '../test_config'

# What an account's privacy settings show, and to whom: the fields on its profile, the lists of what it's in, follows
# and who follows it, a private profile, the calendar key and the feedback summary
class AccountsPrivacyTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  XHR = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }.freeze

  # An account that has signed in, so its profile is public, with every field on its profile filled in
  def profiled_account(**attrs)
    FactoryBot.create(:account, name: 'Robin Profile', has_signed_in: true, phone: '+447700900123', website: 'https://robin.example.com',
                                gender: 'Genderqueer', location: 'Stockholm', date_of_birth: Date.new(1990, 6, 15), **attrs)
  end

  def profile_row(label)
    find(:xpath, "//table//tr[td[1][normalize-space()='#{label}']]")
  end

  test 'email, phone and location start visible only to the people an account follows' do
    account = FactoryBot.create(:account)
    assert_equal ['People I follow'] * 3, [account.email_privacy, account.phone_privacy, account.location_privacy]
  end

  test "each field on a profile shows only to those its privacy lets see it: everyone, the people the account follows, or just them, and to admins" do
    account = profiled_account
    account.set(email_privacy: 'Only me', phone_privacy: 'Public', website_privacy: 'People I follow', gender_privacy: 'Only me',
                location_privacy: 'People I follow', date_of_birth_privacy: 'Only me', bio: 'I grow dandelions', bio_privacy: 'People I follow')
    followee = FactoryBot.create(:account)
    Follow.create!(follower: account, followee: followee)
    follower = FactoryBot.create(:account) # follows the account, which doesn't follow them back
    Follow.create!(follower: follower, followee: account)
    admin = FactoryBot.create(:account, admin: true)
    age = "#{account.age}"

    visit "/u/#{account.username}"
    assert page.has_content?('Robin Profile')
    assert profile_row('Phone').has_content?('+447700900123')
    %w[Email Website Gender Location Age].each { |label| assert page.has_no_xpath?("//table//tr[td[1][normalize-space()='#{label}']]") }
    assert page.has_no_content?('I grow dandelions')

    sign_in(follower)
    visit "/u/#{account.username}"
    assert page.has_content?('+447700900123')
    assert page.has_no_content?('robin.example.com')
    assert page.has_no_content?('Stockholm')
    assert page.has_no_content?(account.email)
    assert page.has_no_content?('I grow dandelions')

    sign_in(followee)
    visit "/u/#{account.username}"
    assert page.has_content?('robin.example.com')
    assert page.has_content?('Stockholm')
    assert page.has_content?('I grow dandelions')
    assert page.has_no_content?(account.email)
    assert page.has_no_content?('Genderqueer')

    [account, admin].each do |viewer|
      sign_in(viewer)
      visit "/u/#{account.username}"
      assert page.has_content?(account.email)
      assert page.has_content?('Genderqueer')
      assert profile_row('Age').has_content?(age)
    end
  end

  test "a field hidden from someone isn't in the profile page or its modal at all" do
    account = profiled_account
    account.set(email_privacy: 'Only me', phone_privacy: 'People I follow', gender_privacy: 'Only me', last_active: 1.day.ago, last_active_privacy: 'Only me',
                bio: 'I grow dandelions', bio_privacy: 'Only me')
    stranger = FactoryBot.create(:account)

    [nil, stranger].each do |viewer|
      viewer ? sign_in_with_rack(viewer) : clear_cookies
      [{}, XHR].each do |headers|
        get "/u/#{account.username}", {}, headers
        assert last_response.ok?
        assert_includes last_response.body, 'Robin Profile'
        [account.email, '+447700900123', 'Genderqueer', 'Last active', 'I grow dandelions'].each { |value| refute_includes last_response.body, value }
      end
    end
  end

  test "an account's organisations, local groups, activities and gatherings are hidden from signed-out visitors, even when public" do
    account = profiled_account(organisations_privacy: 'Public')
    organisation = FactoryBot.create(:organisation, name: 'Secret Society')
    account.organisationships.create!(organisation: organisation)
    assert(%i[organisations local_groups activities gatherings].all? { |p| Account.sensitive?(p) })
    assert(%i[email following followers].none? { |p| Account.sensitive?(p) })

    get "/u/#{account.username}"
    assert last_response.ok?
    refute_includes last_response.body, "/u/#{account.username}/organisations"
    get "/u/#{account.username}/organisations", {}, XHR
    assert_equal 403, last_response.status

    sign_in_with_rack(FactoryBot.create(:account))
    get "/u/#{account.username}"
    assert_includes last_response.body, "/u/#{account.username}/organisations"
    get "/u/#{account.username}/organisations", {}, XHR
    assert last_response.ok?
    assert_includes last_response.body, 'Secret Society'
  end

  test 'who an account follows, and who follows it, show only to those their privacy lets see them' do
    account = profiled_account(following_privacy: 'People I follow', followers_privacy: 'Only me')
    followee = FactoryBot.create(:account, name: 'Fern Followee')
    Follow.create!(follower: account, followee: followee)
    follower = FactoryBot.create(:account, name: 'Felix Follower')
    Follow.create!(follower: follower, followee: account)

    clear_cookies
    get "/u/#{account.username}/following", {}, XHR
    assert_equal 403, last_response.status
    get "/u/#{account.username}/following"
    assert_equal '/accounts/sign_in', URI(last_response.location).path

    sign_in_with_rack(follower)
    get "/u/#{account.username}/following", {}, XHR
    assert_equal 403, last_response.status
    get "/u/#{account.username}/followers", {}, XHR
    assert_equal 403, last_response.status

    sign_in_with_rack(followee)
    get "/u/#{account.username}/following", {}, XHR
    assert last_response.ok?
    assert_includes last_response.body, 'Fern Followee'
    get "/u/#{account.username}/followers", {}, XHR
    assert_equal 403, last_response.status

    [account, FactoryBot.create(:account, admin: true)].each do |viewer|
      sign_in_with_rack(viewer)
      get "/u/#{account.username}/followers", {}, XHR
      assert last_response.ok?
      assert_includes last_response.body, 'Felix Follower'
    end
  end

  test "someone changes a field's privacy on their profile, and others then see it" do
    account = profiled_account
    sign_in(account)
    visit "/u/#{account.username}"
    within(profile_row('Phone')) do
      click_link 'People I follow'
      click_link 'Public'
      assert page.has_link?('Public')
    end
    assert_equal 'Public', account.reload.phone_privacy

    Capybara.reset_sessions!
    visit "/u/#{account.username}"
    assert profile_row('Phone').has_content?('+447700900123')
  end

  test "the privacy routes show and set only the signed-in account's own settings, and only its privacy settings" do
    account = profiled_account
    other = FactoryBot.create(:account)

    clear_cookies
    get '/accounts/privacyable/phone'
    assert_equal '/accounts/new', URI(last_response.location).path
    post '/accounts/set_privacyable/phone', level: 'Public'
    assert_equal '/accounts/new', URI(last_response.location).path

    sign_in_with_rack(account)
    # Naming another account changes nothing but the signed-in account's own setting
    post '/accounts/set_privacyable/phone', level: 'Public', account_id: other.id.to_s, username: other.username
    assert last_response.ok?
    assert_equal 'Public', account.reload.phone_privacy
    assert_equal 'People I follow', other.reload.phone_privacy
    get '/accounts/privacyable/phone', account_id: other.id.to_s
    assert_includes last_response.body, 'bi-globe-europe-africa'

    # Only privacy fields: p names one of Account.privacyables
    post '/accounts/set_privacyable/admin', level: 'Public'
    assert_equal 403, last_response.status
    get '/accounts/privacyable/admin'
    assert_equal 403, last_response.status
    assert_nil account.reload.attributes['admin_privacy']
  end

  test "a private profile says so to others, and its owner makes it public" do
    account = profiled_account(hidden: true)
    visit "/u/#{account.username}"
    assert page.has_content?('That profile is private')

    sign_in(account)
    visit "/u/#{account.username}"
    assert page.has_content?('Your profile is currently private and visible only to you')
    click_link 'Make my profile public'
    assert page.has_content?('Robin Profile')
    assert page.has_no_content?('Your profile is currently private')
    refute account.reload.hidden

    Capybara.reset_sessions!
    visit "/u/#{account.username}"
    assert page.has_content?('Robin Profile')
    assert page.has_no_content?('That profile is private')
  end

  test 'unhiding needs a signed-in account, and marks an account that never signed in as having signed in' do
    account = FactoryBot.create(:account, hidden: true)
    other = FactoryBot.create(:account, hidden: true)

    clear_cookies
    post '/accounts/unhide'
    assert_equal '/accounts/new', URI(last_response.location).path

    sign_in_with_rack(account)
    account.set(has_signed_in: false, sign_ins_count: 0)
    post '/accounts/unhide', account_id: other.id.to_s
    account.reload
    assert_equal [false, true, 1], [account.hidden, account.has_signed_in, account.sign_ins_count]
    assert account.publicly_visible?
    assert other.reload.hidden
  end

  test 'replacing the calendar key ends the old feed URL, and needs a sign in code' do
    account = FactoryBot.create(:account)
    old_key = account.ensure_ics_key!

    account.generate_link_token!
    clear_cookies
    get '/accounts/edit', link_token: account.link_token
    assert last_response.ok?
    post '/accounts/ics_key'
    assert_equal '/accounts/sign_in_code', URI(last_response.location).path
    assert_equal old_key, account.reload.ics_key

    sign_in_with_rack(account)
    post '/accounts/ics_key'
    assert_equal '/accounts/api_key', URI(last_response.location).path
    new_key = account.reload.ics_key
    refute_equal old_key, new_key

    clear_cookies
    get '/events/my.ics', ics_key: old_key
    assert_equal 403, last_response.status
    get '/birthdays.ics', ics_key: old_key
    assert_equal 403, last_response.status
    get '/events/my.ics', ics_key: new_key
    assert last_response.ok?
    assert_includes last_response.body, 'BEGIN:VCALENDAR'
  end

  test 'only the account or an admin refreshes, removes or previews its feedback summary, and only admins more than once a day' do
    account = profiled_account(feedback_summary: 'Wonderfully clear facilitator', feedback_summary_last_refreshed_at: 2.days.ago)
    stranger = FactoryBot.create(:account)

    [nil, stranger].each do |viewer|
      viewer ? sign_in_with_rack(viewer) : clear_cookies
      post "/u/#{account.username}/feedback_summary"
      assert last_response.redirect?
      post "/u/#{account.username}/feedback_summary/delete"
      assert last_response.redirect?
      get "/u/#{account.username}/feedback_summary_email_preview"
      assert last_response.redirect?
    end
    account.reload
    assert_nil account.feedback_summary_requested_at
    assert_equal 'Wonderfully clear facilitator', account.feedback_summary

    sign_in_with_rack(account)
    get "/u/#{account.username}/feedback_summary_email_preview"
    assert last_response.ok?
    post "/u/#{account.username}/feedback_summary", {}, XHR
    assert last_response.ok?
    assert account.reload.feedback_summary_requested_at
    account.set(feedback_summary_requested_at: nil, feedback_summary_last_refreshed_at: 1.hour.ago)
    post "/u/#{account.username}/feedback_summary"
    assert_nil account.reload.feedback_summary_requested_at

    admin = FactoryBot.create(:account, admin: true)
    sign_in_with_rack(admin)
    post "/u/#{account.username}/feedback_summary", {}, XHR
    assert account.reload.feedback_summary_requested_at
    post "/u/#{account.username}/feedback_summary/delete"
    assert_nil account.reload.feedback_summary
  end

  test "anyone reads an account's feedback summary, but only the account and admins are offered to refresh or remove it" do
    account = profiled_account(feedback_summary: 'Wonderfully clear facilitator', feedback_summary_last_refreshed_at: 2.days.ago)

    [nil, FactoryBot.create(:account)].each do |viewer|
      viewer ? sign_in_with_rack(viewer) : clear_cookies
      get "/u/#{account.username}/feedback_summary"
      assert_includes last_response.body, 'Wonderfully clear facilitator'
      refute_includes last_response.body, 'Remove'
      refute_includes last_response.body, 'Refresh'
    end

    sign_in_with_rack(account)
    get "/u/#{account.username}/feedback_summary"
    assert_includes last_response.body, 'Remove'
    assert_includes last_response.body, 'Refresh'
  end
end
