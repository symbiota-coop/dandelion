require_relative '../test_config'
require_relative '../helpers/event_permissions_helpers'

# Who can add and remove co-hosts, and what co-hosting gives them
class EventCohostPermissionsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include EventPermissionsHelpers

  def cohosts_box
    "[data-pagelet-url='/e/#{@event.slug}/cohostships']"
  end

  # On the event's page, adds organisation as a co-host, then waits for the box to reload with its add control showing
  # again
  def add_cohost(organisation)
    within(cohosts_box) { find('#add-organisation').click }
    choose_in_lookup('cohostship_organisation_id', organisation.name)
    within(cohosts_box) { click_button 'Add co-host' }
    assert page.has_css? "#{cohosts_box} #add-organisation"
  end

  # On the event's page, removes organisation as a co-host, then waits for the box to reload with its remove control
  # showing again, which it does while another co-host is left
  def remove_cohost(organisation)
    within(cohosts_box) do
      find('#remove-organisation').click
      select "#{organisation.name} (#{organisation.slug})", from: 'organisation_id'
      click_button 'Remove co-host'
    end
    assert page.has_css? "#{cohosts_box} #remove-organisation"
  end

  test 'event_manager is event admin for cohosted event' do
    covers 'events/only-host-admins-add-cohosts@076df9', 'organisations/org-admins-managers-activity-admins-are-event-admins@a32f62'
    org = FactoryBot.create(:organisation)
    cohost = FactoryBot.create(:organisation)
    manager = add_event_manager(cohost)
    event = FactoryBot.create(:event, organisation: org)
    event.cohostships.create!(organisation: cohost)
    assert Event.admin?(event, manager)
  end

  test 'org admin cannot cohost another org event even when restrict_cohosting is set' do
    create_event
    attacker_org = FactoryBot.create(:organisation, restrict_cohosting: true)
    attacker = attacker_org.account

    sign_in_with_rack(attacker)
    post "/e/#{@event.slug}/cohostships/new", cohostship: { organisation_id: attacker_org.id }

    assert last_response.redirect?
    assert_includes last_response.location, "/e/#{@event.slug}"
    refute @event.cohostships.find_by(organisation: attacker_org)
    refute Event.admin?(@event.reload, attacker)
  end

  test 'event admin can add an unrestricted org as cohost' do
    create_event
    cohost = FactoryBot.create(:organisation)

    sign_in(@account)
    visit "/e/#{@event.slug}"
    add_cohost(cohost)

    assert page.has_css? "#{cohosts_box} a", text: cohost.name
    assert @event.cohostships.find_by(organisation: cohost)
  end

  test 'the host organisation cannot be added as a co-host' do
    covers 'events/host-cannot-be-cohost@eb8558'
    create_event

    sign_in(@account)
    visit "/e/#{@event.slug}"
    add_cohost(@organisation)

    assert page.has_no_css? "#{cohosts_box} a", text: @organisation.name
    assert_nil @event.cohostships.find_by(organisation: @organisation)
    assert_empty @event.reload.cohosts_ids_cache || []
  end

  test 'event admin cannot add a restricted org they do not admin' do
    create_event
    restricted = FactoryBot.create(:organisation, restrict_cohosting: true)

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/cohostships/new", cohostship: { organisation_id: restricted.id }

    assert last_response.redirect?
    assert_includes last_response.location, "/o/#{restricted.slug}"
    refute @event.cohostships.find_by(organisation: restricted)
  end

  test 'event admin can add a restricted org they also admin' do
    create_event
    restricted = FactoryBot.create(:organisation, restrict_cohosting: true)
    restricted.organisationships.create!(account: @account, admin: true)

    sign_in(@account)
    visit "/e/#{@event.slug}"
    add_cohost(restricted)

    assert page.has_css? "#{cohosts_box} a", text: restricted.name
    assert @event.cohostships.find_by(organisation: restricted)
  end

  test 'activity admin cannot add their own org as cohost to see attendee emails' do
    covers 'events/only-host-admins-add-cohosts@076df9'
    covers_route 'POST /e/:slug/cohostships/new'
    create_full_event_hierarchy(event_options: { show_emails: false }, skip_local_group: true)
    activity_admin = FactoryBot.create(:account)
    @activity.activityships.create!(account: activity_admin, admin: true, unsubscribed: false)
    attacker_org = FactoryBot.create(:organisation, account: activity_admin)

    sign_in_with_rack(activity_admin)
    post "/e/#{@event.slug}/cohostships/new", cohostship: { organisation_id: attacker_org.id }

    assert last_response.redirect?
    assert_includes last_response.location, "/e/#{@event.slug}"
    refute @event.cohostships.find_by(organisation: attacker_org)
    refute Event.email_viewer?(@event.reload, activity_admin)
  end

  test 'local group admin cannot add their own org as cohost' do
    covers 'events/only-host-admins-add-cohosts@076df9'
    create_full_event_hierarchy(skip_activity: true)
    local_group_admin = FactoryBot.create(:account)
    @local_group.local_groupships.create!(account: local_group_admin, admin: true, unsubscribed: false)
    attacker_org = FactoryBot.create(:organisation, account: local_group_admin)

    sign_in_with_rack(local_group_admin)
    post "/e/#{@event.slug}/cohostships/new", cohostship: { organisation_id: attacker_org.id }

    assert last_response.redirect?
    assert_includes last_response.location, "/e/#{@event.slug}"
    refute @event.cohostships.find_by(organisation: attacker_org)
    refute Event.email_viewer?(@event.reload, local_group_admin)
  end

  test 'event page shows activity admins the remove cohost control but not the add one' do
    covers 'events/who-can-remove-cohosts@fcec2a'
    create_full_event_hierarchy(skip_local_group: true)
    activity_admin = FactoryBot.create(:account)
    @activity.activityships.create!(account: activity_admin, admin: true, unsubscribed: false)
    @event.cohostships.create!(organisation: FactoryBot.create(:organisation))

    sign_in_with_rack(activity_admin)
    get "/e/#{@event.slug}"

    assert last_response.ok?
    refute_includes last_response.body, 'id="add-organisation"'
    assert_includes last_response.body, 'id="remove-organisation"'
  end

  test 'event page shows local group admins no add cohost control' do
    create_full_event_hierarchy(skip_activity: true)
    local_group_admin = FactoryBot.create(:account)
    @local_group.local_groupships.create!(account: local_group_admin, admin: true, unsubscribed: false)

    sign_in_with_rack(local_group_admin)
    get "/e/#{@event.slug}"

    assert last_response.ok?
    refute_includes last_response.body, 'id="add-organisation"'
  end

  test 'event page shows host organisation admins the add cohost control' do
    covers 'events/only-host-admins-add-cohosts@076df9'
    create_event

    sign_in_with_rack(@account)
    get "/e/#{@event.slug}"

    assert last_response.ok?
    assert_includes last_response.body, 'id="add-organisation"'
  end

  test 'events stats page makes event managers revenue admins of hosted and cohosted events' do
    covers 'organisations/table-event-stats@3be66e'
    covers_route 'GET /o/:slug/events/stats'
    create_event
    # Revenue admins' rows have the allocation columns, which link to the event's rpayments
    @organisation.set(stripe_client_id: 'ca_test')
    manager = add_event_manager(@organisation)
    other_organisation = FactoryBot.create(:organisation)
    cohosted_event = FactoryBot.create(:event, organisation: other_organisation)
    cohosted_event.cohostships.create!(organisation: @organisation)

    sign_in_with_rack(manager)
    get "/o/#{@organisation.slug}/events/stats", table: 1

    assert last_response.ok?
    [@event, cohosted_event].each do |event|
      assert_includes last_response.body, "/e/#{event.slug}/rpayments"
    end
  end

  test 'host event_manager can add a cohost' do
    covers 'events/only-host-admins-add-cohosts@076df9'
    covers_route 'GET /organisations/autocomplete'
    create_event
    manager = add_event_manager(@organisation)
    cohost = FactoryBot.create(:organisation)

    sign_in(manager)
    visit "/e/#{@event.slug}"
    add_cohost(cohost)

    assert page.has_css? "#{cohosts_box} a", text: cohost.name
    assert @event.cohostships.find_by(organisation: cohost)
  end

  test 'activity admin can remove a cohost' do
    covers 'events/who-can-remove-cohosts@fcec2a', 'organisations/org-admins-managers-activity-admins-are-event-admins@a32f62'
    covers_route 'GET /e/:slug/cohostships'
    create_full_event_hierarchy(skip_local_group: true)
    activity_admin = FactoryBot.create(:account)
    @activity.activityships.create!(account: activity_admin, admin: true, unsubscribed: false)
    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    staying = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: staying)

    sign_in(activity_admin)
    visit "/e/#{@event.slug}"
    remove_cohost(cohost)

    assert page.has_no_css? "#{cohosts_box} a", text: cohost.name
    refute @event.cohostships.find_by(organisation: cohost)
    assert @event.cohostships.find_by(organisation: staying)
  end

  test 'facilitator cannot add their own organisation as cohost' do
    covers 'events/facilitator-no-organisation-access@ec2446', 'events/only-host-admins-add-cohosts@076df9'
    create_event
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    attacker_organisation = FactoryBot.create(:organisation, account: facilitator)

    sign_in_with_rack(facilitator)
    post "/e/#{@event.slug}/cohostships/new", cohostship: { organisation_id: attacker_organisation.id.to_s }

    assert last_response.redirect?
    refute @event.cohostships.find_by(organisation: attacker_organisation)
    refute Event.revenue_admin?(@event.reload, facilitator)
    refute Event.email_viewer?(@event, facilitator)
  end

  test 'facilitator cannot remove a cohost' do
    covers 'events/who-can-remove-cohosts@fcec2a'
    covers_route 'POST /e/:slug/cohostships/destroy'
    create_event
    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)

    sign_in_with_rack(facilitator)
    post "/e/#{@event.slug}/cohostships/destroy", organisation_id: cohost.id.to_s

    assert last_response.redirect?
    assert @event.cohostships.find_by(organisation: cohost)
  end

  test 'event admin cannot feature event in a cohost carousel they do not manage' do
    covers 'events/cohost-carousel-feature@022f35'
    covers_route 'POST /e/:slug/cohostships/:cohostship_id'
    create_event
    cohost = FactoryBot.create(:organisation)
    cohostship = @event.cohostships.create!(organisation: cohost)
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)

    sign_in_with_rack(facilitator)
    post "/e/#{@event.slug}/cohostships/#{cohostship.id}", cohostship: { featured: '1' }
    refute cohostship.reload.featured
  end

  test "co-host admins can feature an event in their organisation's carousels, and other event admins aren't offered it" do
    covers 'events/cohost-carousel-feature@022f35'
    covers_route 'GET /e/:slug/cohosts'
    create_event
    cohost = FactoryBot.create(:organisation)
    cohostship = @event.cohostships.create!(organisation: cohost)
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)

    sign_in(facilitator)
    visit "/e/#{@event.slug}/cohosts"
    assert page.has_link? cohost.name
    assert page.has_no_field? 'cohostship_featured', visible: :all

    sign_in(cohost.account)
    visit "/e/#{@event.slug}/cohosts"
    find('#cohostship_featured', visible: :all).click
    # The box saves as soon as it's ticked, and the page comes back with it ticked
    assert page.has_css? '#cohostship_featured[checked]', visible: :all
    assert cohostship.reload.featured
  end

  test 'event admins cannot list their event under another organisation through the cohost caches' do
    create_event(prices: [0])
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    sign_in_with_rack(@account)

    [{ cohosts_ids_cache: [other_organisation.id.to_s] }, { hosts_ids_cache: [other_organisation.id.to_s] }].each do |event_params|
      error = assert_raises(RuntimeError) { post "/e/#{@event.slug}/edit", event: event_params }
      assert_match(/are protected/, error.message)
    end
    assert_empty other_organisation.events_including_cohosted.to_a
    assert_empty other_organisation.cohosted_events.to_a
  end

  test 'admins of a co-host organisation and local group admins are event admins' do
    covers 'organisations/org-admins-managers-activity-admins-are-event-admins@a32f62'
    covers_route 'GET /e/:slug/edit'
    create_full_event_hierarchy(skip_activity: true)
    cohost = FactoryBot.create(:organisation)
    local_group_admin = FactoryBot.create(:account)
    @local_group.local_groupships.create!(account: local_group_admin, admin: true, unsubscribed: false)
    refute Event.admin?(@event, cohost.account)

    @event.cohostships.create!(organisation: cohost)
    @event.reload
    assert Event.admin?(@event, cohost.account)
    assert Event.admin?(@event, local_group_admin)

    sign_in_with_rack(local_group_admin)
    get "/e/#{@event.slug}/edit"
    assert last_response.ok?
  end

  test 'host organisation admins, event managers and local group admins can remove a cohost' do
    covers 'events/who-can-remove-cohosts@fcec2a'
    create_full_event_hierarchy(skip_activity: true)
    manager = add_event_manager(@organisation)
    local_group_admin = FactoryBot.create(:account)
    @local_group.local_groupships.create!(account: local_group_admin, admin: true, unsubscribed: false)

    @event.cohostships.create!(organisation: FactoryBot.create(:organisation))

    [@account, manager, local_group_admin].each do |account|
      cohost = FactoryBot.create(:organisation)
      @event.cohostships.create!(organisation: cohost)

      sign_in(account)
      visit "/e/#{@event.slug}"
      remove_cohost(cohost)

      assert page.has_no_css? "#{cohosts_box} a", text: cohost.name
      refute @event.cohostships.find_by(organisation: cohost), 'cohost was not removed'
    end
  end
end
