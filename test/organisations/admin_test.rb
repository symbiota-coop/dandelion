require_relative '../test_config'
require_relative '../helpers/event_permissions_helpers'

# Running an organisation: tiers, notes on followers and their emails, removing and exporting them, bans, welcome
# emails, feedback, its feedback summary and deleting it, and who may do each
class OrganisationsAdminTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include EventPermissionsHelpers

  XHR = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }.freeze

  # A follower, an event manager, someone who doesn't follow, another organisation's admin and someone signed out
  def outsiders
    other_organisation = FactoryBot.create(:organisation)
    [add_member(@organisation), add_event_manager(@organisation), FactoryBot.create(:account), other_organisation.account, nil]
  end

  # The CSV each send_followers_csv job queued would email, with whom it would go to
  def followers_csvs
    sent = []
    deliver = ->(*, to:, attachments: {}, **) { sent << [to, attachments['followers.csv']] }
    Mailer.stub(:deliver, deliver) { Delayed::Job.and(handler: /send_followers_csv/).each(&:invoke_job) }
    sent
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # In the browser
  # ═══════════════════════════════════════════════════════════════════════════

  test 'an admin creates a tier, edits it and deletes it' do
    covers 'organisations/table-activities-local-groups-carousels-tiers@49b568'
    covers_route 'GET /o/:slug/tiers'
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/tiers"
    click_link 'Create a tier'
    fill_in 'Name', with: 'Gold'
    fill_in 'Threshold', with: '50'
    fill_in 'Discount', with: '10'
    click_button 'Create organisation tier'
    assert page.has_link? 'Gold'
    organisation_tier = @organisation.organisation_tiers.find_by(name: 'Gold')
    assert_equal [50, 10], [organisation_tier.threshold, organisation_tier.discount]

    click_link 'Gold'
    fill_in 'Name', with: 'Platinum'
    fill_in 'Discount', with: '20'
    click_button 'Update organisation tier'
    assert page.has_link? 'Platinum'
    assert_equal ['Platinum', 20], [organisation_tier.reload.name, organisation_tier.discount]

    click_link 'Platinum'
    click_link_and_confirm 'Delete'
    assert page.has_link? 'Create a tier'
    assert page.has_no_link? 'Platinum'
    assert_empty @organisation.organisation_tiers
  end

  test "an admin writes notes on a follower and turns their emails off and on from the followers page" do
    covers 'organisations/table-manage-followers-credits-bans@7b2dbd'
    create_organisation
    follower = add_member(@organisation)
    organisationship = @organisation.organisationships.find_by(account: follower)

    sign_in(@account)
    visit "/o/#{@organisation.slug}/followers"
    find("#notes-#{organisationship.id}").set('Met at the spring gathering')
    within("[data-pagelet-url='/organisationships/#{organisationship.id}/notes']") { find("button[aria-label='Save notes']").click }
    wait_until('notes not saved yet') { organisationship.reload.notes == 'Met at the spring gathering' }

    find("#organisationship-subscribed-#{organisationship.id}").click
    assert page.has_css? "#organisationship-subscribed-#{organisationship.id}:not([checked])"
    assert organisationship.reload.unsubscribed?
    find("#organisationship-subscribed-#{organisationship.id}").click
    assert page.has_css? "#organisationship-subscribed-#{organisationship.id}[checked]"
    refute organisationship.reload.unsubscribed?

    visit "/o/#{@organisation.slug}/followers"
    assert page.has_field? "notes-#{organisationship.id}", with: 'Met at the spring gathering'
  end

  test 'an admin removes a follower from the followers page' do
    create_organisation
    follower = add_member(@organisation)
    follower.set(name: 'Fern Follower')
    organisationship = @organisation.organisationships.find_by(account: follower)

    sign_in(@account)
    visit "/o/#{@organisation.slug}/followers"
    assert page.has_content? 'Fern Follower'
    find("a[href='/organisationships/#{organisationship.id}/destroy']").click
    page.document.find('.popover').click_button 'Confirm'
    assert page.has_content? 'Displaying 1 person'
    assert page.has_no_content? 'Fern Follower'
    assert_nil Organisationship.find(organisationship.id)
    assert Account.find(follower.id)
  end

  test 'an admin asks for the followers CSV, which is emailed to them, and uploads a CSV of followers' do
    covers_route 'POST /o/:slug/followers'
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/followers"
    click_link 'Download CSV'
    assert page.has_content? 'You will receive the CSV via email shortly'
    sent = followers_csvs
    assert_equal [@account], sent.map(&:first)
    assert_includes sent.first.last, @account.email

    file = Tempfile.new(%w[followers .csv])
    file.write("name,email\nAda Lovelace,Ada@example.com\n")
    file.close
    accept_alert { click_link 'Upload CSV' }
    attach_file 'csv', file.path
    assert page.has_content? 'The followers will be added shortly'
    Delayed::Job.and(handler: /import_from_csv/).each(&:invoke_job)
    ada = Account.find_by(email: 'ada@example.com')
    assert_equal 'Ada Lovelace', ada.name
    assert @organisation.organisationships.find_by(account: ada)
  ensure
    file&.unlink
  end

  test 'an admin chooses whether they receive feedback' do
    covers_route 'GET /o/:slug/activities'
    covers_route 'GET /o/:slug/local_groups'
    create_organisation
    organisationship = @organisation.organisationships.find_by(account: @account)
    assert organisationship.receive_feedback?

    sign_in(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Receiving feedback'
    assert page.has_link? 'Not receiving feedback'
    refute organisationship.reload.receive_feedback?

    click_link 'Not receiving feedback'
    assert page.has_link? 'Receiving feedback'
    assert organisationship.reload.receive_feedback?
  end

  test 'an admin bans email addresses and sets the welcome emails' do
    covers 'organisations/table-manage-followers-credits-bans@7b2dbd'
    covers_route 'GET /o/:slug/banned_emails'
    covers_route 'GET /o/:slug/emails'
    covers_route 'POST /o/:slug/banned_emails'
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/banned_emails"
    fill_in 'Banned emails', with: "Spammer@example.com\ntroll@example.com"
    click_button 'Update organisation'
    assert page.has_content? 'Your settings were saved'
    assert_equal %w[spammer@example.com troll@example.com], @organisation.reload.banned_emails_a

    visit "/o/#{@organisation.slug}/emails"
    fill_in 'Welcome email subject', with: 'Welcome to the meadow'
    click_button 'Update organisation'
    assert page.has_content? 'Your settings were saved'
    assert_equal 'Welcome to the meadow', @organisation.reload.welcome_subject
  end

  test "an admin deletes the organisation by typing its name, and a name that doesn't match deletes nothing" do
    covers 'organisations/table-delete-organisation@467e21'
    covers_route 'GET /o/:slug/delete'
    covers_route 'GET /organisations'
    covers_route 'POST /o/:slug/destroy'
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/delete"
    fill_in 'organisation_name', with: 'Something else'
    click_button 'Delete organisation'
    assert page.has_content? "The name you typed didn't match the organisation name"
    assert Organisation.find(@organisation.id)

    fill_in 'organisation_name', with: @organisation.name
    click_button 'Delete organisation'
    assert page.has_content? 'The organisation was deleted'
    assert_nil Organisation.find(@organisation.id)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Who may, through Rack
  # ═══════════════════════════════════════════════════════════════════════════

  test "followers, event managers, others, another organisation's admin and people signed out can't open the admin pages or change anything" do
    covers 'organisations/table-manage-followers-credits-bans@7b2dbd', 'organisations/table-activities-local-groups-carousels-tiers@49b568', 'organisations/table-delete-organisation@467e21'
    covers_route 'GET /o/:slug/stats'
    create_organisation
    organisation_tier = @organisation.organisation_tiers.create!(name: 'Gold', threshold: 50, discount: 10)
    victim = add_member(@organisation)
    organisationship = @organisation.organisationships.find_by(account: victim)
    organisationship.set(notes: 'Private note')
    path = "/o/#{@organisation.slug}"
    csv = Rack::Test::UploadedFile.new(StringIO.new("name,email\nIntruder,intruder@example.com\n"), 'text/csv', original_filename: 'followers.csv')

    outsiders.each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      ["#{path}/tiers", "#{path}/organisation_tiers/#{organisation_tier.id}/edit", "#{path}/emails", "#{path}/stats",
       "#{path}/subscribed/#{organisationship.id}", "/organisationships/#{organisationship.id}/notes"].each do |url|
        get url
        assert_redirected_to path
      end
      get "#{path}/followers.csv"
      assert_redirected_to path

      [
        ["#{path}/organisation_tiers/new", { organisation_tier: { name: 'Forged', threshold: 1, discount: 99 } }],
        ["#{path}/organisation_tiers/#{organisation_tier.id}/edit", { organisation_tier: { name: 'Forged', discount: 99 } }],
        ["#{path}/organisation_tiers/#{organisation_tier.id}/destroy", {}],
        ["#{path}/add_follower", { email: 'intruder@example.com' }],
        ["#{path}/followers", { csv: csv }],
        ["#{path}/subscribed/#{organisationship.id}", {}],
        ["/organisationships/#{organisationship.id}/notes", { notes: 'Overwritten' }],
        ["/organisationships/#{organisationship.id}/destroy", {}],
        ["#{path}/banned_emails", { organisation: { banned_emails: victim.email } }],
        ["#{path}/emails", { organisation: { welcome_subject: 'Forged' } }],
        ["#{path}/edit", { organisation: { name: 'Forged' } }],
        ["#{path}/feedback_summary", {}],
        ["#{path}/feedback_summary/delete", {}]
      ].each do |url, params|
        post url, params
        assert_redirected_to path
      end

      # Asked for in the page, as a pagelet does, they're refused outright
      get "/organisationships/#{organisationship.id}/notes", {}, XHR
      assert_equal 403, last_response.status
    end

    assert_equal ['Gold', 10], [organisation_tier.reload.name, organisation_tier.discount]
    assert_equal 1, @organisation.organisation_tiers.count
    assert_nil Account.find_by(email: 'intruder@example.com')
    assert_empty Delayed::Job.and(handler: /send_followers_csv|import_from_csv/)
    organisationship.reload
    assert_equal 'Private note', organisationship.notes
    refute organisationship.unsubscribed?
    @organisation.reload
    assert_nil @organisation.banned_emails
    assert_nil @organisation.welcome_subject
    refute_equal 'Forged', @organisation.name
    assert_nil @organisation.feedback_summary_requested_at
  end

  test "another organisation's admin can't reach this organisation's tiers or followers under their own organisation's URL" do
    covers_route 'GET /o/:slug/organisation_tiers/:organisation_tier_id/edit'
    covers_route 'GET /o/:slug/subscribed/:organisationship_id'
    covers_route 'POST /o/:slug/organisation_tiers/:organisation_tier_id/destroy'
    covers_route 'POST /o/:slug/subscribed/:organisationship_id'
    create_organisation
    organisation_tier = @organisation.organisation_tiers.create!(name: 'Gold', threshold: 50, discount: 10)
    organisationship = @organisation.organisationships.find_by(account: add_member(@organisation))
    other_organisation = FactoryBot.create(:organisation)
    other_path = "/o/#{other_organisation.slug}"
    sign_in_with_rack(other_organisation.account)

    get "#{other_path}/organisation_tiers/#{organisation_tier.id}/edit"
    assert_equal 404, last_response.status
    post "#{other_path}/organisation_tiers/#{organisation_tier.id}/edit", organisation_tier: { name: 'Forged' }
    assert_equal 404, last_response.status
    post "#{other_path}/organisation_tiers/#{organisation_tier.id}/destroy"
    assert_equal 404, last_response.status
    assert_equal 'Gold', organisation_tier.reload.name

    get "#{other_path}/subscribed/#{organisationship.id}"
    assert_equal 404, last_response.status
    post "#{other_path}/subscribed/#{organisationship.id}"
    assert_equal 404, last_response.status
    refute organisationship.reload.unsubscribed?

    post "#{other_path}/organisationships/unadmin", account_id: @account.id
    assert_equal 404, last_response.status
    assert Organisation.admin?(@organisation, @account)
  end

  test "notes on a follower are seen and set only by the organisation's admins, and set nothing else" do
    covers_route 'GET /organisationships/:id/notes'
    covers_route 'POST /organisationships/:id/notes'
    create_organisation
    follower = add_member(@organisation)
    organisationship = @organisation.organisationships.find_by(account: follower)
    organisationship.set(notes: 'Prefers morning sessions')

    sign_in_with_rack(follower)
    get "/organisationships/#{organisationship.id}/notes", {}, XHR
    assert_equal 403, last_response.status
    get "/o/#{@organisation.slug}"
    refute_includes last_response.body, 'Prefers morning sessions'

    sign_in_with_rack(@account)
    get "/organisationships/#{organisationship.id}/notes", {}, XHR
    assert last_response.ok?
    assert_includes last_response.body, 'Prefers morning sessions'

    post "/organisationships/#{organisationship.id}/notes", notes: 'Prefers evenings', admin: '1', event_manager: '1', unsubscribed: '1'
    assert last_response.ok?
    organisationship.reload
    assert_equal 'Prefers evenings', organisationship.notes
    refute organisationship.admin
    refute organisationship.event_manager
    refute organisationship.unsubscribed
  end

  test "an admin chooses receiving feedback for themselves only, and a site admin who doesn't follow has nothing to choose" do
    covers_route 'POST /o/:slug/receive_feedback/:f'
    create_organisation
    other_admin = add_member(@organisation, admin: true, receive_feedback: true)
    own = @organisation.organisationships.find_by(account: @account)
    others = @organisation.organisationships.find_by(account: other_admin)

    sign_in_with_rack(@account)
    post "/o/#{@organisation.slug}/receive_feedback/0", account_id: other_admin.id
    refute own.reload.receive_feedback?
    assert others.reload.receive_feedback?

    site_admin = FactoryBot.create(:account, admin: true)
    sign_in_with_rack(site_admin)
    post "/o/#{@organisation.slug}/receive_feedback/1"
    assert_equal 404, last_response.status
    assert_nil @organisation.organisationships.find_by(account: site_admin)
  end

  test 'a removed follower stays an account, and a follower of another organisation is removed only by its own admins' do
    covers_route 'POST /organisationships/:id/destroy'
    create_organisation
    follower = add_member(@organisation)
    organisationship = @organisation.organisationships.find_by(account: follower)
    other_organisation = FactoryBot.create(:organisation)
    elsewhere = other_organisation.organisationships.create!(account: follower)

    sign_in_with_rack(@account)
    post "/organisationships/#{elsewhere.id}/destroy"
    assert_redirected_to "/o/#{other_organisation.slug}"
    assert Organisationship.find(elsewhere.id)

    post "/organisationships/#{organisationship.id}/destroy"
    assert_nil Organisationship.find(organisationship.id)
    assert Account.find(follower.id)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Forged forms
  # ═══════════════════════════════════════════════════════════════════════════

  test "a forged settings or welcome emails form can't set the organisation's protected fields" do
    covers_route 'POST /o/:slug/emails'
    create_organisation
    sign_in_with_rack(@account)
    { 'feedback_summary' => 'Forged', 'followers_count' => '100000', 'paid_up' => '1', 'stripe_connect_json' => '{}', 'hide_from_homepage' => '1' }.each do |field, value|
      %w[edit emails].each do |page|
        error = assert_raises(RuntimeError) { post "/o/#{@organisation.slug}/#{page}", organisation: { name: 'Renamed', field => value } }
        assert_includes error.message, field
      end
    end
    @organisation.reload
    refute_equal 'Renamed', @organisation.name
    assert_nil @organisation.feedback_summary
    assert_nil @organisation.stripe_connect_json
    refute @organisation.hide_from_homepage
  end

  test "a forged tier form can't make a tier for another organisation" do
    covers_route 'POST /o/:slug/organisation_tiers/new'
    create_organisation
    other_organisation = FactoryBot.create(:organisation)
    sign_in_with_rack(@account)
    post "/o/#{@organisation.slug}/organisation_tiers/new", organisation_tier: { name: 'Gold', threshold: 50, discount: 10, organisation_id: other_organisation.id }
    assert_redirected_to "/o/#{@organisation.slug}/tiers"
    assert @organisation.organisation_tiers.find_by(name: 'Gold')
    assert_empty other_organisation.organisation_tiers
  end

  test 'a tier without a threshold or discount, or edited without a name, is not saved' do
    create_organisation
    organisation_tier = @organisation.organisation_tiers.create!(name: 'Gold', threshold: 50, discount: 10)
    sign_in_with_rack(@account)

    post "/o/#{@organisation.slug}/organisation_tiers/new", organisation_tier: { name: 'Silver', threshold: '' }
    assert last_response.ok?
    assert_includes last_response.body, 'There was an error saving the tier'
    assert_nil @organisation.organisation_tiers.find_by(name: 'Silver')

    post "/o/#{@organisation.slug}/organisation_tiers/#{organisation_tier.id}/edit", organisation_tier: { name: '' }
    assert last_response.ok?
    assert_includes last_response.body, 'There was an error saving the tier'
    assert_equal 'Gold', organisation_tier.reload.name
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Exporting followers
  # ═══════════════════════════════════════════════════════════════════════════

  test "the followers CSV goes only to the admin who asked, with each follower's email and whether they unsubscribed, and not their notes" do
    covers_route 'GET /o/:slug/followers'
    create_organisation
    subscribed = add_member(@organisation)
    unsubscribed = add_member(@organisation)
    @organisation.organisationships.find_by(account: subscribed).set(notes: 'Prefers morning sessions')
    @organisation.organisationships.find_by(account: unsubscribed).set(unsubscribed: true)
    other_admin = add_member(@organisation, admin: true)
    elsewhere = FactoryBot.create(:organisation).organisationships.create!(account: FactoryBot.create(:account)).account

    sign_in_with_rack(@account)
    get "/o/#{@organisation.slug}/followers.csv"
    assert last_response.redirect?

    sent = followers_csvs
    assert_equal [@account], sent.map(&:first)
    rows = CSV.parse(sent.first.last, headers: true)
    assert_equal [@account, subscribed, unsubscribed, other_admin].map(&:email).sort, rows.map { |row| row['email'] }.sort
    refute_includes rows.map { |row| row['email'] }, elsewhere.email
    assert_equal '1', rows.find { |row| row['email'] == unsubscribed.email }['unsubscribed']
    assert_nil rows.find { |row| row['email'] == subscribed.email }['unsubscribed']
    refute_includes sent.first.last, 'Prefers morning sessions'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Feedback summary
  # ═══════════════════════════════════════════════════════════════════════════

  test 'an admin refreshes the feedback summary once a day and removes it, and others see it without the controls' do
    covers_route 'GET /o/:slug/feedback_summary'
    covers_route 'POST /o/:slug/feedback_summary'
    covers_route 'POST /o/:slug/feedback_summary/delete'
    create_organisation
    @organisation.set(feedback_summary: 'Warm and welcoming', feedback_summary_last_refreshed_at: 2.days.ago)

    [FactoryBot.create(:account), nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get "/o/#{@organisation.slug}/feedback_summary", {}, XHR
      assert last_response.ok?
      assert_includes last_response.body, 'Warm and welcoming'
      refute_includes last_response.body, 'Refresh'
      refute_includes last_response.body, 'Remove'
    end

    sign_in_with_rack(@account)
    get "/o/#{@organisation.slug}/feedback_summary", {}, XHR
    assert_includes last_response.body, 'Refresh'
    assert_includes last_response.body, 'Remove'

    post "/o/#{@organisation.slug}/feedback_summary", {}, XHR
    assert last_response.ok?
    assert @organisation.reload.feedback_summary_requested_at
    assert Delayed::Job.and(handler: /generate_requested_feedback_summary/).exists?

    @organisation.set(feedback_summary_requested_at: nil, feedback_summary_last_refreshed_at: 1.hour.ago)
    post "/o/#{@organisation.slug}/feedback_summary"
    assert last_response.redirect?
    assert_nil @organisation.reload.feedback_summary_requested_at

    post "/o/#{@organisation.slug}/feedback_summary/delete"
    assert last_response.redirect?
    @organisation.reload
    assert_nil @organisation.feedback_summary
    assert @organisation.feedback_summary_last_refreshed_at > 1.minute.ago
  end
end
