require_relative '../test_config'
require_relative '../helpers/organisations_helpers'
require_relative '../helpers/event_permissions_helpers'

# A local group's admins, stats, mailer, follower imports and deletion, who may use each, and its old URLs
class OrganisationsLocalGroupRoutesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include OrganisationsHelpers
  include EventPermissionsHelpers

  XHR = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }.freeze

  # Another group of the organisation, with an admin of its own who is no admin of @local_group
  def other_local_group
    FactoryBot.create(:local_group, organisation: @organisation, account: FactoryBot.create(:account))
  end

  # People who aren't admins of @local_group: a follower, another group's admin, another organisation's admin, and
  # someone signed out
  def local_group_outsiders
    [local_group_follower, other_local_group.account, FactoryBot.create(:organisation).account, nil]
  end

  def local_group_admins_box
    "[data-pagelet-url='#{@local_group.path}/local_groupships/admins']"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # In the browser
  # ═══════════════════════════════════════════════════════════════════════════

  test "an admin makes a follower an admin from the group's page, and isn't offered removing the last admin" do
    covers_route 'GET /o/:organisation_slug/lg/:slug/local_groupships/admins'
    covers_route 'POST /o/:organisation_slug/lg/:slug/local_groupships/admin'
    create_local_group
    person = local_group_follower(name: 'Fern Follower', has_signed_in: true)
    local_groupship = @local_group.local_groupships.find_by(account: person)

    sign_in(@account)
    visit @local_group.path
    assert page.has_css? "#{local_group_admins_box} .add-role-toggle"
    assert page.has_no_css? "#{local_group_admins_box} .remove-role-toggle"
    within(local_group_admins_box) { find('.add-role-toggle').click }
    choose_in_lookup('local_groupship_account_id', person.name)
    within(local_group_admins_box) { click_button 'Add admin' }
    assert page.has_css? "#{local_group_admins_box} img[alt='#{person.name}']"
    assert page.has_css? "#{local_group_admins_box} .remove-role-toggle"
    assert local_groupship.reload.admin?
    assert_equal 1, @local_group.local_groupships.and(account: person).count

    # The new admin can now manage the group
    sign_in(person)
    visit "#{@local_group.path}/edit"
    assert page.has_button? 'Update local group'
  end

  test 'an admin uploads a CSV of followers, who are added in the background, new accounts made for new emails' do
    covers_route 'POST /o/:organisation_slug/lg/:slug/followers'
    create_local_group
    existing = FactoryBot.create(:account, name: 'Existing Person')
    file = Tempfile.new(['followers', '.csv'])
    file.write("name,email\nNew Person,new.person@example.com\nExisting Person,#{existing.email}\n")
    file.close

    sign_in(@account)
    visit "#{@local_group.path}/followers"
    accept_alert('CSV, two columns, with headers: name, email') { click_link 'Upload CSV' }
    attach_file 'csv', file.path
    assert page.has_content? 'The followers will be added shortly'
    Delayed::Job.and(handler: /import_from_csv/).each(&:invoke_job)

    newcomer = Account.find_by(email: 'new.person@example.com')
    assert newcomer
    assert @local_group.local_groupships.find_by(account: newcomer)
    assert @local_group.local_groupships.find_by(account: existing)
    visit "#{@local_group.path}/followers"
    assert page.has_content? 'New Person'
  ensure
    file&.unlink
  end

  test 'an admin sees the event stats, audience stats and mailer of the group, with only its own events and mails' do
    covers_route 'GET /o/:organisation_slug/lg/:slug/events/stats'
    covers_route 'GET /o/:organisation_slug/lg/:slug/stats'
    covers_route 'GET /o/:organisation_slug/lg/:slug/pmails'
    create_local_group
    elsewhere = other_local_group
    create_event(as: :own_event, local_group: @local_group, name: 'Spring picnic')
    create_event(as: :other_event, local_group: elsewhere, name: 'Autumn picnic')
    FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "local_group:#{@local_group.id}", subject: 'Plans for spring')
    FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "local_group:#{elsewhere.id}", subject: 'Plans for autumn')

    sign_in(@account)
    visit "#{@local_group.path}/events/stats"
    assert page.has_content? 'Spring picnic'
    assert page.has_no_content? 'Autumn picnic'

    visit "#{@local_group.path}/stats"
    assert page.has_css? 'h2', text: 'Followers'
    assert page.has_css? 'h2', text: 'Locations'

    visit "#{@local_group.path}/pmails"
    assert page.has_content? 'Plans for spring'
    assert page.has_no_content? 'Plans for autumn'
  end

  test 'an admin deletes the group, which keeps its events in the organisation but ends its followings and deletes its mails' do
    covers_route 'POST /o/:organisation_slug/lg/:slug/destroy'
    create_local_group
    person = local_group_follower
    create_event(local_group: @local_group)
    pmail = FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "local_group:#{@local_group.id}")

    sign_in(@account)
    visit "#{@local_group.path}/edit"
    click_link_and_confirm 'Delete'
    assert page.has_current_path? "/o/#{@organisation.slug}/local_groups"
    assert page.has_no_content? @local_group.name

    assert_nil LocalGroup.find(@local_group.id)
    assert Event.find(@event.id)
    @event.reload
    assert_nil @event.local_group_id
    assert_equal @organisation, @event.organisation
    assert_empty LocalGroupship.and(local_group_id: @local_group.id)
    assert Account.find(person.id)
    assert_nil Pmail.find(pmail.id)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Who may, through Rack
  # ═══════════════════════════════════════════════════════════════════════════

  test "people who aren't the group's admins can't see its admins box, stats or mailer, or change its admins, followers or existence" do
    create_local_group
    person = local_group_follower(name: 'Private Person')
    create_event(local_group: @local_group, name: 'Secret summit', secret: true)
    FactoryBot.create(:pmail, organisation: @organisation, account: @account, to_option: "local_group:#{@local_group.id}", subject: 'Confidential plans')
    path = @local_group.path

    local_group_outsiders.each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      ["#{path}/local_groupships/admins", "#{path}/stats", "#{path}/pmails"].each do |url|
        get url
        assert_redirected_to path
      end
      get "#{path}/local_groupships/admins", {}, XHR
      assert_equal 403, last_response.status
      get "#{path}/events/stats", table: 1
      assert_redirected_to path
      ['Secret summit', 'Confidential plans', person.email].each { |secret| refute_includes last_response.body, secret }
      get "#{path}/events/stats", { table: 1 }, XHR
      assert_equal 403, last_response.status
      refute_includes last_response.body, 'Secret summit'

      [
        ["#{path}/local_groupships/admin", { local_groupship: { account_id: (account || person).id } }],
        ["#{path}/followers", { csv: csv_upload("name,email\nIntruder,intruder@example.com\n") }],
        ["#{path}/destroy", {}]
      ].each do |url, params|
        post url, params
        assert_redirected_to path
      end
    end

    assert LocalGroup.find(@local_group.id)
    assert_equal [@account.id], @local_group.admins.pluck(:id)
    assert_empty Delayed::Job.and(handler: /import_from_csv/)
  end

  test "organisation admins who are not the group's admins make admins, and making an admin under another group's URL makes them that group's admin only" do
    create_local_group
    organisation_admin = FactoryBot.create(:account, location: nil) # so following the organisation doesn't make them follow the group
    @organisation.organisationships.create!(account: organisation_admin).set(admin: true)
    newcomer = FactoryBot.create(:account)

    sign_in_with_rack(organisation_admin)
    get "#{@local_group.path}/local_groupships/admins", {}, XHR
    assert last_response.ok?
    post "#{@local_group.path}/local_groupships/admin", local_groupship: { account_id: newcomer.id }
    assert last_response.redirect?
    assert @local_group.local_groupships.find_by(account: newcomer).admin?

    person = local_group_follower
    elsewhere = other_local_group
    sign_in_with_rack(elsewhere.account)
    post "#{elsewhere.path}/local_groupships/admin", local_groupship: { account_id: person.id }
    refute @local_group.local_groupships.find_by(account: person).admin?
    assert elsewhere.local_groupships.find_by(account: person).admin?
  end

  test "a CSV without an email column isn't imported" do
    create_local_group
    sign_in_with_rack(@account)
    post "#{@local_group.path}/followers", csv: csv_upload("name\nNo Email\n")
    assert_redirected_to "#{@local_group.path}/followers"
    follow_redirect!
    assert_includes last_response.body, 'The CSV needs a column headed email'
    assert_empty Delayed::Job.and(handler: /import_from_csv/)
  end

  test "an unsubscribe link unsubscribes only the person it's for, and someone who didn't follow the group is kept out of its emails" do
    create_local_group
    person = local_group_follower(email_confirmed: true)
    other = local_group_follower
    person.generate_link_token!

    post "#{@local_group.path}/unsubscribe", link_token: person.link_token, account_id: other.id
    assert_redirected_to '/accounts/subscriptions'
    assert @local_group.local_groupships.find_by(account: person).unsubscribed?
    refute @local_group.local_groupships.find_by(account: other).unsubscribed?

    stranger = FactoryBot.create(:account)
    sign_in_with_rack(stranger)
    post "#{@local_group.path}/unsubscribe"
    assert @local_group.local_groupships.find_by(account: stranger).unsubscribed?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Old URLs
  # ═══════════════════════════════════════════════════════════════════════════

  test 'old URLs naming the group by id redirect to its slug URL, keeping the method and query, and unknown ids are not found' do
    covers_route 'GET /local_groups/:id'
    covers_route 'POST /local_groups/:id/*'
    create_local_group

    get "/local_groups/#{@local_group.id}", tab: 'events'
    assert_equal 307, last_response.status
    assert_equal "#{@local_group.path}?tab=events", URI(last_response.location).request_uri

    post "/local_groups/#{@local_group.id}/unsubscribe"
    assert_equal 307, last_response.status
    assert_equal "#{@local_group.path}/unsubscribe", URI(last_response.location).path

    get "/local_groups/#{BSON::ObjectId.new}"
    assert_equal 404, last_response.status
    post "/local_groups/#{@local_group.slug}/unsubscribe"
    assert_equal 404, last_response.status
  end
end
