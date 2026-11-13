require_relative '../test_config'
require_relative '../helpers/organisations_helpers'
require_relative '../helpers/event_permissions_helpers'

# An activity's admins, followers, stats, mailer, feedback summary and deletion, who may use each, and its old URLs
class OrganisationsActivityAdminTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include OrganisationsHelpers
  include EventPermissionsHelpers

  XHR = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }.freeze

  # @activity in @organisation, whose owner (@account) is an organisation admin and the activity's admin
  def create_activity(**attrs)
    create_organisation
    @activity = FactoryBot.create(:activity, organisation: @organisation, **attrs)
  end

  def activity_follower(activity = @activity, **attrs)
    account = FactoryBot.create(:account, **attrs)
    activity.activityships.create!(account: account)
    account
  end

  # Another activity of the organisation, with an admin of its own who is no admin of @activity
  def other_activity
    FactoryBot.create(:activity, organisation: @organisation, account: FactoryBot.create(:account))
  end

  # People who aren't admins of @activity: a follower, another activity's admin, another organisation's admin, and
  # someone signed out
  def activity_outsiders
    [activity_follower, other_activity.account, FactoryBot.create(:organisation).account, nil]
  end

  def sign_in_as(account)
    account ? sign_in_with_rack(account) : clear_cookies
  end

  def activity_admins_box
    "[data-pagelet-url='#{@activity.path}/activityships/admins']"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # In the browser
  # ═══════════════════════════════════════════════════════════════════════════

  test "an admin makes a follower an admin from the activity's page and removes them again, and isn't offered removing the last admin" do
    covers_route 'GET /o/:organisation_slug/a/:slug/activityships/admins'
    covers_route 'POST /o/:organisation_slug/a/:slug/activityships/admin'
    covers_route 'POST /o/:organisation_slug/a/:slug/activityships/unadmin'
    create_activity
    person = activity_follower(name: 'Fern Follower', has_signed_in: true)
    activityship = @activity.activityships.find_by(account: person)

    sign_in(@account)
    visit @activity.path
    assert page.has_no_css? "#{activity_admins_box} .remove-role-toggle"
    within(activity_admins_box) { find('.add-role-toggle').click }
    choose_in_lookup('activityship_account_id', person.name)
    within(activity_admins_box) { click_button 'Add admin' }
    assert page.has_css? "#{activity_admins_box} img[alt='#{person.name}']"
    assert activityship.reload.admin?
    assert_equal 1, @activity.activityships.and(account: person).count

    within(activity_admins_box) do
      find('.remove-role-toggle').click
      select "#{person.name} (#{person.username})", from: 'account_id'
      click_button_and_confirm 'Remove admin'
    end
    assert page.has_css? "#{activity_admins_box} .add-role-toggle"
    assert page.has_no_css? "#{activity_admins_box} img[alt='#{person.name}']"
    assert page.has_no_css? "#{activity_admins_box} .remove-role-toggle"
    refute activityship.reload.admin?
    assert @activity.activityships.find_by(account: @account).admin?
  end

  test 'an admin turns a follower\'s emails off and on, and removes them from the followers' do
    covers_route 'GET /o/:organisation_slug/a/:slug/subscribed/:activityship_id'
    covers_route 'POST /o/:organisation_slug/a/:slug/subscribed/:activityship_id'
    covers_route 'POST /activityships/:id/destroy'
    create_activity
    person = activity_follower
    activityship = @activity.activityships.find_by(account: person)
    switch = "#activityship-subscribed-#{activityship.id}"

    sign_in(@account)
    visit "#{@activity.path}/followers"
    find(switch).click
    # The switch saves as it's flicked, and its box comes back with it off
    assert page.has_css? "#{switch}:not([checked])"
    assert activityship.reload.unsubscribed?
    find(switch).click
    assert page.has_css? "#{switch}[checked]"
    refute activityship.reload.unsubscribed?

    find("a[href='/activityships/#{activityship.id}/destroy']").click
    page.document.find('.popover').click_button 'Confirm'
    # Only the admin's own following is left
    assert page.has_css? "a[href^='/activityships/']", count: 1
    assert page.has_no_css? switch
    assert_nil Activityship.find(activityship.id)
    assert Account.find(person.id)
    assert @activity.activityships.find_by(account: @account)
  end

  test 'an admin uploads a CSV of followers, who are added in the background, new accounts made for new emails' do
    covers_route 'POST /o/:organisation_slug/a/:slug/followers'
    create_activity
    existing = FactoryBot.create(:account, name: 'Existing Person')
    file = Tempfile.new(['followers', '.csv'])
    file.write("name,email\nNew Person,new.person@example.com\nExisting Person,#{existing.email}\n")
    file.close

    sign_in(@account)
    visit "#{@activity.path}/followers"
    accept_alert('CSV, two columns, with headers: name, email') { click_link 'Upload CSV' }
    attach_file 'csv', file.path
    assert page.has_content? 'The followers will be added shortly'
    Delayed::Job.and(handler: /import_from_csv/).each(&:invoke_job)

    newcomer = Account.find_by(email: 'new.person@example.com')
    assert newcomer
    assert @activity.activityships.find_by(account: newcomer)
    assert @activity.activityships.find_by(account: existing)
    visit "#{@activity.path}/followers"
    assert page.has_content? 'New Person'
  ensure
    file&.unlink
  end

  test "a CSV without an email column isn't imported" do
    create_activity
    sign_in_with_rack(@account)
    post "#{@activity.path}/followers", csv: csv_upload("name\nNo Email\n")
    assert_redirected_to "#{@activity.path}/followers"
    follow_redirect!
    assert_includes last_response.body, 'The CSV needs a column headed email'
    assert_empty Delayed::Job.and(handler: /import_from_csv/)
  end

  test 'an admin sees the event stats, audience stats and mailer of the activity, with only its own events and mails' do
    covers_route 'GET /o/:organisation_slug/a/:slug/events/stats'
    covers_route 'GET /o/:organisation_slug/a/:slug/stats'
    covers_route 'GET /o/:organisation_slug/a/:slug/pmails'
    create_activity
    elsewhere = other_activity
    create_event(as: :own_event, activity: @activity, name: 'Spring retreat')
    create_event(as: :other_event, activity: elsewhere, name: 'Autumn retreat')
    FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "activity:#{@activity.id}", subject: 'Plans for spring')
    FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "activity:#{elsewhere.id}", subject: 'Plans for autumn')

    sign_in(@account)
    visit "#{@activity.path}/events/stats"
    assert page.has_content? 'Spring retreat'
    assert page.has_no_content? 'Autumn retreat'

    visit "#{@activity.path}/stats"
    assert page.has_css? 'h2', text: 'Followers'
    assert page.has_css? 'h2', text: 'Locations'

    visit "#{@activity.path}/pmails"
    assert page.has_content? 'Plans for spring'
    assert page.has_no_content? 'Plans for autumn'
  end

  test "an admin deletes the activity, which keeps its events in the organisation but ends its followings and deletes its mails" do
    covers_route 'POST /o/:organisation_slug/a/:slug/destroy'
    create_activity
    person = activity_follower
    create_event(activity: @activity)
    pmail = FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "activity:#{@activity.id}")

    sign_in(@account)
    visit "#{@activity.path}/edit"
    click_link_and_confirm 'Delete'
    assert page.has_current_path? "/o/#{@organisation.slug}/activities"
    assert page.has_no_content? @activity.name

    assert_nil Activity.find(@activity.id)
    assert @event.reload
    assert_nil @event.activity_id
    assert_equal @organisation, @event.organisation
    assert_empty Activityship.and(activity_id: @activity.id)
    assert Account.find(person.id)
    assert_nil Pmail.find(pmail.id)
  end

  test "a follower opens the unsubscribe link signed out, which signs them in, and unsubscribes from the activity's emails, staying a follower" do
    covers_route 'GET /o/:organisation_slug/a/:slug/unsubscribe'
    covers_route 'POST /o/:organisation_slug/a/:slug/unsubscribe'
    create_activity
    person = activity_follower(email_confirmed: true)
    other = activity_follower
    person.generate_link_token!

    visit "#{@activity.path}/unsubscribe?link_token=#{person.link_token}"
    assert page.has_content? "Are you sure you want to unsubscribe #{person.email}"
    click_button 'Yes, unsubscribe'
    assert page.has_content? "You were unsubscribed from #{@activity.name}"
    assert @activity.activityships.find_by(account: person).unsubscribed?
    refute @activity.activityships.find_by(account: other).unsubscribed?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Who may, through Rack
  # ═══════════════════════════════════════════════════════════════════════════

  test "people who aren't the activity's admins can't see its admins box, stats or mailer, or change its admins, followers or existence" do
    create_activity
    person = activity_follower(name: 'Private Person')
    activityship = @activity.activityships.find_by(account: person)
    create_event(activity: @activity, name: 'Secret summit', secret: true)
    FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "activity:#{@activity.id}", subject: 'Confidential plans')
    path = @activity.path

    activity_outsiders.each do |account|
      sign_in_as(account)
      ["#{path}/activityships/admins", "#{path}/stats", "#{path}/pmails", "#{path}/subscribed/#{activityship.id}"].each do |url|
        get url
        assert_redirected_to path
      end
      get "#{path}/events/stats", table: 1
      assert_redirected_to path
      ['Secret summit', 'Confidential plans', person.email].each { |secret| refute_includes last_response.body, secret }
      get "#{path}/events/stats", { table: 1 }, XHR
      assert_equal 403, last_response.status
      refute_includes last_response.body, 'Secret summit'

      [
        ["#{path}/activityships/admin", { activityship: { account_id: (account || person).id } }],
        ["#{path}/activityships/unadmin", { account_id: @account.id }],
        ["#{path}/subscribed/#{activityship.id}", {}],
        ["#{path}/followers", { csv: csv_upload("name,email\nIntruder,intruder@example.com\n") }],
        ["/activityships/#{activityship.id}/destroy", {}],
        ["#{path}/destroy", {}]
      ].each do |url, params|
        post url, params
        assert_redirected_to path
      end
    end

    assert Activity.find(@activity.id)
    assert_equal [@account.id], @activity.admins.pluck(:id)
    assert Activityship.find(activityship.id)
    refute activityship.reload.unsubscribed?
    assert_empty Delayed::Job.and(handler: /import_from_csv/)
  end

  test 'organisation admins who are not the activity\'s admins manage it, as its own admins do' do
    create_activity
    organisation_admin = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: organisation_admin).set(admin: true)
    person = activity_follower

    sign_in_with_rack(organisation_admin)
    get "#{@activity.path}/activityships/admins", {}, XHR
    assert last_response.ok?
    post "#{@activity.path}/activityships/admin", activityship: { account_id: person.id }
    assert @activity.activityships.find_by(account: person).admin?
    post "#{@activity.path}/activityships/unadmin", account_id: person.id
    refute @activity.activityships.find_by(account: person).admin?
  end

  test 'making someone an admin who does not follow the activity makes them a follower too' do
    create_activity
    newcomer = FactoryBot.create(:account)
    sign_in_with_rack(@account)
    post "#{@activity.path}/activityships/admin", activityship: { account_id: newcomer.id }
    assert last_response.redirect?
    assert @activity.activityships.find_by(account: newcomer).admin?

    post "#{@activity.path}/activityships/unadmin", account_id: FactoryBot.create(:account).id
    assert_equal 404, last_response.status
  end

  test "another activity's admin can't reach this activity's followers or admins under their own activity's URL" do
    create_activity
    person = activity_follower
    activityship = @activity.activityships.find_by(account: person)
    elsewhere = other_activity
    sign_in_with_rack(elsewhere.account)

    get "#{elsewhere.path}/subscribed/#{activityship.id}"
    assert_equal 404, last_response.status
    post "#{elsewhere.path}/subscribed/#{activityship.id}"
    assert_equal 404, last_response.status
    refute activityship.reload.unsubscribed?

    post "#{elsewhere.path}/activityships/unadmin", account_id: @account.id
    assert_equal 404, last_response.status
    assert @activity.activityships.find_by(account: @account).admin?

    # Making this activity's follower an admin under their own activity's URL makes them an admin of their own activity only
    post "#{elsewhere.path}/activityships/admin", activityship: { account_id: person.id }
    refute activityship.reload.admin?
    assert elsewhere.activityships.find_by(account: person).admin?
  end

  test 'unsubscribing needs signing in, changes only one\'s own following, and makes no following for someone who has none' do
    create_activity
    person = activity_follower
    other = activity_follower
    stranger = FactoryBot.create(:account)
    path = "#{@activity.path}/unsubscribe"

    get path
    assert_redirected_to '/accounts/new'
    post path
    assert_redirected_to '/accounts/new'

    sign_in_with_rack(person)
    get path
    assert last_response.ok?
    assert_includes last_response.body, person.email
    post path, account_id: other.id
    assert_redirected_to '/accounts/subscriptions'
    assert @activity.activityships.find_by(account: person).unsubscribed?
    refute @activity.activityships.find_by(account: other).unsubscribed?

    sign_in_with_rack(stranger)
    post path
    assert_redirected_to '/accounts/subscriptions'
    assert_nil @activity.activityships.find_by(account: stranger)
  end

  test "an unsubscribe link signs in only the person it's for, and unsubscribes only them" do
    create_activity
    person = activity_follower(email_confirmed: true)
    other = activity_follower
    person.generate_link_token!

    post "#{@activity.path}/unsubscribe", link_token: person.link_token
    assert_redirected_to '/accounts/subscriptions'
    assert @activity.activityships.find_by(account: person).unsubscribed?
    refute @activity.activityships.find_by(account: other).unsubscribed?

    clear_cookies
    post "#{@activity.path}/unsubscribe", link_token: 'not-a-token'
    assert_redirected_to '/accounts/sign_in'
    refute @activity.activityships.find_by(account: other).unsubscribed?
  end

  test "the follow button's pagelet is for people signed in, and a page asking for it goes to the activity" do
    covers_route 'GET /o/:organisation_slug/a/:slug/activityship'
    create_activity(privacy: 'open')
    get "#{@activity.path}/activityship", {}, XHR
    assert_equal 403, last_response.status
    get "#{@activity.path}/activityship"
    assert_redirected_to '/accounts/new'

    sign_in_with_rack(activity_follower)
    get "#{@activity.path}/activityship", { membership_toggle: '1' }, XHR
    assert last_response.ok?
    assert_includes last_response.body, 'Showing on your profile'
    get "#{@activity.path}/activityship"
    assert_redirected_to @activity.path
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Feedback summary
  # ═══════════════════════════════════════════════════════════════════════════

  test 'an admin refreshes the feedback summary once a day and removes it, and others see it without the controls and can change nothing' do
    covers_route 'GET /o/:organisation_slug/a/:slug/feedback_summary'
    covers_route 'POST /o/:organisation_slug/a/:slug/feedback_summary'
    covers_route 'POST /o/:organisation_slug/a/:slug/feedback_summary/delete'
    create_activity
    @activity.set(feedback_summary: 'Warm and welcoming', feedback_summary_last_refreshed_at: 2.days.ago)
    path = "#{@activity.path}/feedback_summary"

    activity_outsiders.each do |account|
      sign_in_as(account)
      get path, {}, XHR
      assert last_response.ok?
      assert_includes last_response.body, 'Warm and welcoming'
      refute_includes last_response.body, 'Refresh'
      refute_includes last_response.body, 'Remove'
      post path
      assert_redirected_to @activity.path
      post "#{path}/delete"
      assert_redirected_to @activity.path
    end
    @activity.reload
    assert_equal 'Warm and welcoming', @activity.feedback_summary
    assert_nil @activity.feedback_summary_requested_at

    sign_in_with_rack(@account)
    get path, {}, XHR
    assert_includes last_response.body, 'Refresh'
    assert_includes last_response.body, 'Remove'

    post path, {}, XHR
    assert last_response.ok?
    assert @activity.reload.feedback_summary_requested_at
    assert Delayed::Job.and(handler: /generate_requested_feedback_summary/).exists?

    @activity.set(feedback_summary_requested_at: nil, feedback_summary_last_refreshed_at: 1.hour.ago)
    post path
    assert last_response.redirect?
    assert_nil @activity.reload.feedback_summary_requested_at

    post "#{path}/delete"
    assert last_response.redirect?
    @activity.reload
    assert_nil @activity.feedback_summary
    assert @activity.feedback_summary_last_refreshed_at > 1.minute.ago
  end

  test "a locked activity's feedback and its summary are for its admins only, as its page is" do
    create_activity
    create_event(activity: @activity)
    @event.event_feedbacks.create!(account: FactoryBot.create(:account), rating: 5, public_answers: [['How was it?', 'Glowing review']])
    # Locked after its event, as creating an event unlocks its activity
    @activity.set(locked: true, feedback_summary: 'Warm and welcoming')
    pages = { "#{@activity.path}/feedback_summary" => 'Warm and welcoming', "#{@activity.path}/show_feedback" => 'Glowing review' }

    activity_outsiders.each do |account|
      sign_in_as(account)
      pages.each do |url, text|
        get url, {}, XHR
        assert_equal 403, last_response.status
        refute_includes last_response.body, text
      end
      get "#{@activity.path}/show_feedback", minimal: 1
      assert_redirected_to "/o/#{@organisation.slug}"
    end

    sign_in_with_rack(@account)
    pages.each do |url, text|
      get url, {}, XHR
      assert last_response.ok?
      assert_includes last_response.body, text
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Old URLs
  # ═══════════════════════════════════════════════════════════════════════════

  test 'old URLs naming the activity by id redirect to its slug URL, keeping the method and query, and unknown ids are not found' do
    covers_route 'GET /activities/:id/*'
    covers_route 'POST /activities/:id/*'
    create_activity

    get "/activities/#{@activity.id}/events/stats", from: '2020-01-01'
    assert_equal 307, last_response.status
    assert_equal "#{@activity.path}/events/stats?from=2020-01-01", URI(last_response.location).request_uri

    post "/activities/#{@activity.id}/unsubscribe"
    assert_equal 307, last_response.status
    assert_equal "#{@activity.path}/unsubscribe", URI(last_response.location).path

    get "/activities/#{BSON::ObjectId.new}/edit"
    assert_equal 404, last_response.status
    post "/activities/#{@activity.slug}/unsubscribe"
    assert_equal 404, last_response.status
  end
end
