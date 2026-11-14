require_relative '../test_config'
require_relative '../helpers/event_permissions_helpers'

# Who is an event admin, and what each kind of event admin can do
class EventPermissionsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include EventPermissionsHelpers

  test 'organisations_for_creating_events includes org when account has event_manager on organisationship' do
    org = FactoryBot.create(:organisation)
    other = add_event_manager(org)
    assert_includes other.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'organisations_for_creating_events includes org when account is org admin on organisationship' do
    covers 'organisations/table-create-events@8599fc'
    org = FactoryBot.create(:organisation)
    other = add_member(org, admin: true)
    assert_includes other.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'organisations_for_creating_events does not include org for plain follower only' do
    org = FactoryBot.create(:organisation)
    follower = add_member(org)
    refute_includes follower.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'organisations_for_creating_events includes org from activity admin' do
    org = FactoryBot.create(:organisation)
    activity = FactoryBot.create(:activity, organisation: org)
    other = FactoryBot.create(:account)
    activity.activityships.create!(account: other, admin: true, unsubscribed: false)
    assert_includes other.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'organisations_for_creating_events includes org from local group admin' do
    org = FactoryBot.create(:organisation)
    local_group = FactoryBot.create(:local_group, organisation: org)
    other = FactoryBot.create(:account)
    local_group.local_groupships.create!(account: other, admin: true, unsubscribed: false)
    assert_includes other.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'can_create_events_for_organisation? is false for unrelated activity admin' do
    org = FactoryBot.create(:organisation)
    other_org = FactoryBot.create(:organisation, account: org.account)
    activity = FactoryBot.create(:activity, organisation: other_org)
    other = FactoryBot.create(:account)
    activity.activityships.create!(account: other, admin: true, unsubscribed: false)
    refute Organisation.can_create_events_for_organisation?(org, other)
  end

  test 'event is valid for org-wide create when account has event_manager' do
    covers 'organisations/event-manager-creates-and-edits-events@3f0102'
    org = FactoryBot.create(:organisation, allow_event_submissions: false)
    manager = add_event_manager(org)
    event = FactoryBot.build(:event, organisation: org, account: manager, last_saved_by: manager, duplicate: false)
    assert event.valid?, event.errors.full_messages.join(', ')
  end

  test 'event_manager is event admin for organisation event' do
    covers 'organisations/event-manager-creates-and-edits-events@3f0102', 'organisations/org-admins-managers-activity-admins-are-event-admins@a32f62'
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org)
    assert Event.admin?(event, manager)
  end

  test 'event_manager is email viewer when show_emails is false' do
    covers 'organisations/attendee-emails-admins-and-managers-only@10b712', 'organisations/table-see-attendee-emails@ae1847'
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, show_emails: false)
    assert Event.email_viewer?(event, manager)
  end

  test 'cohost event_manager is email viewer when show_emails is false' do
    covers 'organisations/attendee-emails-admins-and-managers-only@10b712'
    org = FactoryBot.create(:organisation)
    cohost = FactoryBot.create(:organisation)
    manager = add_event_manager(cohost)
    event = FactoryBot.create(:event, organisation: org, show_emails: false)
    event.cohostships.create!(organisation: cohost)
    assert Event.email_viewer?(event, manager)
  end

  test 'event is invalid for org-wide create when account is only a follower' do
    org = FactoryBot.create(:organisation, allow_event_submissions: false)
    follower = add_member(org)
    event = FactoryBot.build(:event, organisation: org, account: follower, last_saved_by: follower, duplicate: false)
    refute event.valid?
    assert_includes event.errors[:organisation], "- you don't have permission to create events for this organisation"
  end

  test 'GET /events/new with organisation_id allows event_manager' do
    covers 'organisations/event-manager-creates-and-edits-events@3f0102', 'organisations/table-create-events@8599fc'
    org = FactoryBot.create(:organisation, contribution_not_required: true)
    manager = add_event_manager(org)
    sign_in(manager)
    visit "/events/new?organisation_id=#{org.id}"
    assert page.has_content?('Event title*')
  end

  test 'GET /events/new with organisation_id redirects for plain follower' do
    covers 'organisations/table-create-events@8599fc'
    org = FactoryBot.create(:organisation, contribution_not_required: true)
    follower = add_member(org)
    sign_in(follower)
    visit "/events/new?organisation_id=#{org.id}"
    assert page.has_current_path?('/events', ignore_query: true)
    assert page.has_content? "don't have permission to create events for this organisation"
  end

  test 'requests that started before a redirect, finishing after it, keep its flash message' do
    org = FactoryBot.create(:organisation, contribution_not_required: true)
    sign_in_with_rack(add_member(org))
    get '/'
    cookies_before = last_request.env['HTTP_COOKIE']

    get "/events/new?organisation_id=#{org.id}"
    assert last_response.redirect?
    # The favicon and a pagelet, sent with the session from before the redirect
    get '/images/logos/black-on-transparent-sq.png', {}, { 'HTTP_COOKIE' => cookies_before }
    assert last_response.ok?
    get '/', {}, { 'HTTP_COOKIE' => cookies_before, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
    assert last_response.ok?

    get '/events'
    assert_includes last_response.body, 'permission to create events for this organisation'
  end

  test 'org event manager can delete their own event' do
    covers 'organisations/table-delete-events@f21a92'
    covers_route 'POST /e/:slug/destroy'
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, account: manager, last_saved_by: manager)
    sign_in(manager)
    visit "/e/#{event.slug}/delete"
    choose 'Delete event'
    click_button 'Delete event'
    click_button 'Yes, delete event'
    assert page.has_current_path?("/o/#{org.slug}/events", ignore_query: true)
    assert page.has_content?('The event was deleted')
    assert event.reload.deleted?
  end

  test 'org event manager cannot delete another account event' do
    covers 'organisations/table-delete-events@f21a92'
    covers_route 'GET /e/:slug/delete'
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org)
    sign_in(manager)
    visit "/e/#{event.slug}/delete"
    assert page.has_content?("Please ask an admin of #{org.name} to cancel or delete the event")
    assert page.has_no_button?('Cancel event')
    refute event.reload.deleted?
  end

  test 'org admin can delete any organisation event' do
    covers 'organisations/org-admins-managers-activity-admins-are-event-admins@a32f62', 'organisations/table-delete-events@f21a92'
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, account: manager, last_saved_by: manager)
    sign_in(org.account)
    visit "/e/#{event.slug}/delete"
    choose 'Delete event'
    click_button 'Delete event'
    click_button 'Yes, delete event'
    assert page.has_current_path?("/o/#{org.slug}/events", ignore_query: true)
    assert event.reload.deleted?
  end

  test 'a cancelled event keeps its page, showing the cancellation message' do
    covers 'events/cancel-or-delete-event@69b41c'
    org = FactoryBot.create(:organisation)
    event = FactoryBot.create(:event, organisation: org, account: org.account, last_saved_by: org.account)
    sign_in(org.account)
    visit "/e/#{event.slug}/delete"
    fill_in 'Cancellation message (optional)', with: "Sorry, the venue flooded.\nWe'll be back in spring."
    click_button 'Cancel event'
    click_button 'Yes, cancel event'
    assert page.has_content?('This event has been cancelled')
    assert page.has_content?('Sorry, the venue flooded.')
    assert page.has_content?(event.name)
    assert event.reload.deleted?
  end

  test 'a deleted event loses its page' do
    covers 'events/cancel-or-delete-event@69b41c'
    org = FactoryBot.create(:organisation)
    event = FactoryBot.create(:event, organisation: org, account: org.account, last_saved_by: org.account)
    sign_in(org.account)
    visit "/e/#{event.slug}/delete"
    assert page.has_field?('Cancellation message (optional)')
    choose 'Delete event'
    assert page.has_button?('Delete event')
    assert page.has_no_field?('Cancellation message (optional)')
    click_button 'Delete event'
    click_button 'Yes, delete event'
    assert page.has_content?('The event was deleted')
    visit "/e/#{event.slug}"
    assert page.has_content?("we couldn't find that page")
    assert page.has_no_content?('This event has been cancelled')
  end

  test 'a cancelled event page answers 410 Gone, and only as HTML' do
    covers_route 'GET /e/:slug'
    create_event(prices: [0])
    @event.set(cancelled: true, cancellation_message: 'Cancelled, sorry')
    @event.destroy
    get "/e/#{@event.slug}"
    assert_equal 410, last_response.status
    assert_includes last_response.body, 'Cancelled, sorry'
    get "/e/#{@event.slug}.json"
    assert_equal 404, last_response.status
  end

  test "a cancelled locked event's page is only for its admins" do
    create_event(prices: [0], locked: true)
    @event.set(cancelled: true, cancellation_message: 'Cancelled, sorry')
    @event.destroy
    get "/e/#{@event.slug}"
    assert last_response.redirect?, last_response.status.to_s
    refute_includes last_response.body, 'Cancelled, sorry'
    sign_in_with_rack(@organisation.account)
    get "/e/#{@event.slug}"
    assert_equal 410, last_response.status
    assert_includes last_response.body, 'Cancelled, sorry'
  end

  test 'organisation_id and account_id cannot be reassigned on update' do
    create_event(prices: [0])
    assert_cannot_reassign_organisation_or_account(@event)
  end

  test 'activity and local group must belong to the event organisation' do
    create_event
    other_org = FactoryBot.create(:organisation)
    foreign_activity = FactoryBot.create(:activity, organisation: other_org)
    foreign_local_group = FactoryBot.create(:local_group, organisation: other_org)

    @event.activity = foreign_activity
    @event.last_saved_by = @account
    refute @event.valid?
    assert_includes @event.errors[:activity], 'must belong to this organisation'

    @event.reload
    @event.local_group = foreign_local_group
    @event.last_saved_by = @account
    refute @event.valid?
    assert_includes @event.errors[:local_group], 'must belong to this organisation'
  end

  test 'event facilitator cannot assign an activity they do not admin' do
    covers 'events/facilitator-no-organisation-access@ec2446'
    create_full_event_hierarchy
    other_activity = FactoryBot.create(:activity, organisation: @organisation)
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)

    @event.activity = other_activity
    @event.last_saved_by = facilitator
    refute @event.valid?
    assert_includes @event.errors[:activity], "- you don't have permission to create events for this activity"
  end

  test 'event facilitator cannot bulk update other activity events' do
    covers 'events/facilitator-no-organisation-access@ec2446'
    create_full_event_hierarchy
    other = FactoryBot.create(:event, organisation: @organisation, activity: @activity, name: 'Keep me')
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)

    refute @event.can_bulk_update_activity_events?(facilitator)

    @event.name = 'Overwrite'
    @event.update_activity_events = '1'
    @event.last_saved_by = facilitator
    refute @event.valid?
    assert_includes @event.errors[:update_activity_events], "- you don't have permission to update all events in this activity"

    @event.update_activity_events = nil
    assert @event.save
    @event.update_activity_events = '1'
    @event.bulk_update_activity_events_without_delay
    assert_equal 'Keep me', other.reload.name
  end

  test 'event facilitator cannot enable show_emails or featured' do
    covers 'organisations/table-feature-events-show-emails@6842a0'
    create_event(prices: [0], show_emails: false, featured: false)
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)

    sign_in_with_rack(facilitator)
    [
      { show_emails: '1', featured: '1' },
      { show_emails: '1', featured: '1', last_saved_by_id: @account.id },
      { show_emails: '1', featured: '1', duplicate: '1' },
      { show_emails: '1', featured: '1', last_saved_by_id: @account.id, duplicate: '1' }
    ].each do |event_params|
      # mass_assigning drops last_saved_by_id and duplicate, so they can't get round the check
      post "/e/#{@event.slug}/edit", event: event_params
      refute last_response.redirect?
      @event.reload
      refute @event.show_emails, "show_emails changed for #{event_params.keys}"
      refute @event.featured, "featured changed for #{event_params.keys}"
    end
  end

  test 'event facilitator cannot change revenue share fields' do
    covers 'events/facilitator-no-organisation-access@ec2446', 'organisations/table-change-revenue-sharer@a04837', 'organisations/revenue-fields-activity-local-group-admins@2eb0aa'
    create_organisation(stripe_client_id: 'ca_test')
    create_event(prices: [0])
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    facilitator.organisationships.create!(
      organisation: @organisation,
      stripe_connect_json: { 'stripe_user_id' => 'acct_facilitator' }.to_json
    )

    sign_in_with_rack(facilitator)
    hijack = {
      organiser_id: '',
      revenue_sharer_id: facilitator.id.to_s,
      revenue_share_to_revenue_sharer: '100',
      profit_share_to_organiser: '50',
      stripe_revenue_adjustment: '20'
    }
    [
      hijack,
      hijack.merge(last_saved_by_id: @account.id),
      hijack.merge(duplicate: '1'),
      hijack.merge(last_saved_by_id: @account.id, duplicate: '1')
    ].each do |event_params|
      # mass_assigning drops last_saved_by_id and duplicate, so they can't get round the check
      post "/e/#{@event.slug}/edit", event: event_params
      refute last_response.redirect?
      @event.reload
      assert_nil @event.revenue_sharer_id, "revenue_sharer set for #{event_params.keys}"
      assert_equal 0, @event.revenue_share_to_revenue_sharer
      assert_equal 0, @event.profit_share_to_organiser
      assert_equal 0, @event.stripe_revenue_adjustment
    end
  end

  test 'event facilitators see the revenue share fields disabled, and can still save the event' do
    create_organisation(stripe_client_id: 'ca_test')
    create_event(prices: [0])
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)

    sign_in(facilitator)
    visit "/e/#{@event.slug}/edit"
    click_link 'Revenue'
    assert page.has_field? 'event_profit_share_to_organiser', disabled: true
    assert page.has_field? 'event_revenue_sharer_id', disabled: true, visible: :all
    click_link 'Basics'
    fill_in 'Event title*', with: 'Still editable'
    click_button 'Update event'

    assert page.has_content? 'The event was saved'
    assert_equal 'Still editable', @event.reload.name
  end

  test 'organisation admin can change revenue share fields' do
    covers 'organisations/table-change-revenue-sharer@a04837'
    create_organisation(stripe_client_id: 'ca_test')
    create_event(prices: [0])
    sharer = FactoryBot.create(:account, name: 'Sasha Sharer', has_signed_in: true)
    sharer.organisationships.create!(
      organisation: @organisation,
      stripe_connect_json: { 'stripe_user_id' => 'acct_sharer' }.to_json
    )

    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    click_link 'Revenue'
    choose_in_lookup('event_revenue_sharer_id', sharer.name)
    fill_in 'event_revenue_share_to_revenue_sharer', with: '100'
    # An event has an organiser or a revenue sharer, not both
    click_link 'Basics'
    find('#event_organiser_id + .select2 .select2-selection__clear').click
    click_button 'Update event'

    assert page.has_content? 'The event was saved'
    @event.reload
    assert_equal sharer.id, @event.revenue_sharer_id
    assert_equal 100, @event.revenue_share_to_revenue_sharer
    assert_nil @event.organiser_id
  end

  test 'non-revenue-admin cannot set a revenue sharer on create' do
    create_organisation(stripe_client_id: 'ca_test', allow_event_submissions: true)
    submitter = FactoryBot.create(:account)
    submitter.organisationships.create!(
      organisation: @organisation,
      stripe_connect_json: { 'stripe_user_id' => 'acct_submitter' }.to_json
    )

    event = Event.new(
      name: 'Submitted',
      start_time: 1.month.from_now,
      end_time: 1.month.from_now + 1.day,
      location: 'Online',
      currency: 'GBP',
      organisation: @organisation,
      account: submitter,
      last_saved_by: submitter,
      revenue_sharer: submitter,
      revenue_share_to_revenue_sharer: 100
    )
    refute event.save
    assert_includes event.errors[:revenue_sharer], '- you cannot change this setting'
    assert_includes event.errors[:revenue_share_to_revenue_sharer], '- you cannot change this setting'

    event.revenue_sharer = nil
    event.revenue_share_to_revenue_sharer = nil
    assert event.save, event.errors.full_messages.join(', ')
    assert_equal submitter.id, event.organiser_id
  end

  test 'organisation admin can enable show_emails and featured' do
    covers 'organisations/table-feature-events-show-emails@6842a0'
    create_event(prices: [0], show_emails: false, featured: false)

    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    find('label[for="event_featured"]').click
    click_link 'Everything else'
    find('label[for="event_show_emails"]').click
    click_button 'Update event'

    assert page.has_content? 'The event was saved'
    @event.reload
    assert @event.show_emails
    assert @event.featured
    assert_equal @account.id, @event.last_saved_by_id
  end

  test 'org event manager can assign an activity and bulk update its events' do
    create_full_event_hierarchy
    manager = add_event_manager(@organisation)
    other_activity = FactoryBot.create(:activity, organisation: @organisation)
    other = FactoryBot.create(:event, organisation: @organisation, activity: other_activity, name: 'Old name')

    @event.activity = other_activity
    @event.last_saved_by = manager
    assert @event.valid?, @event.errors.full_messages.join(', ')
    assert @event.can_bulk_update_activity_events?(manager)

    @event.name = 'Manager copy'
    @event.update_activity_events = '1'
    assert @event.save
    @event.bulk_update_activity_events_without_delay
    assert_equal 'Manager copy', other.reload.name
  end

  test 'activity admin can bulk update future activity events' do
    create_full_event_hierarchy
    other = FactoryBot.create(:event, organisation: @organisation, activity: @activity, name: 'Old name', extra_info_for_ticket_email: 'old zoom')

    assert @event.can_bulk_update_activity_events?(@account)

    @event.name = 'Shared title'
    @event.extra_info_for_ticket_email = 'new zoom'
    @event.update_activity_events = '1'
    @event.last_saved_by = @account
    assert @event.save
    @event.bulk_update_activity_events_without_delay

    other.reload
    assert_equal 'Shared title', other.name
    assert_equal 'new zoom', other.extra_info_for_ticket_email
  end

  test 'event admins cannot set the contribution to Dandelion' do
    create_event(prices: [0])
    sign_in_with_rack(@account)

    [{ fixed_contribution_gbp: '-1000' }, { cap_gbp: '-1000' }].each do |event_params|
      error = assert_raises(RuntimeError) { post "/e/#{@event.slug}/edit", event: event_params }
      assert_match(/are protected/, error.message)
    end
    @event.reload
    assert_nil @event.fixed_contribution_gbp
    assert_nil @event.cap_gbp

    @event.cap_gbp = -1
    @event.fixed_contribution_gbp = -1
    refute @event.valid?
    assert @event.errors[:cap_gbp].any?
    assert @event.errors[:fixed_contribution_gbp].any?
  end

  test 'event admins cannot stop checkout donations going to Dandelion' do
    covers_route 'POST /events/new'
    create_event(prices: [0])
    sign_in_with_rack(@account)

    [:new, :edit].each do |action|
      path = action == :new ? '/events/new' : "/e/#{@event.slug}/edit"
      error = assert_raises(RuntimeError) { post path, event: { donations_to_organisation: '1' } }
      assert_match(/are protected/, error.message)
    end
    refute @event.reload.donations_to_organisation?
  end

  test 'atproto_uri is protected from mass assignment' do
    assert_includes Event.protected_attributes, 'atproto_uri'
  end

  test 'protected_attributes list only keys that form_attributes would let through' do
    Mongoid.models.select { |model| model.respond_to?(:protected_attributes) }.each do |model|
      already_dropped = model.protected_attributes.map(&:to_s) - model.form_attributes
      assert_empty already_dropped, "#{model.name}.protected_attributes lists keys mass_assigning already drops"
    end
  end

  test 'mass_assigning keeps only form attributes, not setters Mongoid and Dragonfly generate' do
    params = {
      'name' => 'Event', 'tag_names' => 'a,b', 'update_tag_names' => 'true', 'update_activity_events' => '1',
      'activity_id' => 'x', 'image' => 'file', 'remove_image' => '1',
      'organisation_id' => 'x', 'ticket_type_ids' => ['x'], 'tickets' => ['x'], 'deleted_at' => 'x', 'created_at' => 'x',
      'image_uid' => 'x', 'retained_image' => 'x', 'image_width_unmagic' => 'x', 'prevent_order_refunds' => '1'
    }

    assigned = Dandelion::App.new!.mass_assigning(params, Event)

    assert_equal %w[activity_id image name remove_image tag_names update_activity_events update_tag_names], assigned.keys.sort
  end

  test 'an unknown currency is escaped in the checkout total, not run as HTML' do
    app = Dandelion::App.new!
    app.instance_variable_set(:@event, Event.new(currency: '<img src=x onerror=alert(1)>'))

    html = app.currency_input_row(label: 'Total', field_name: 'totalDisplay', field_id: 'totalDisplay', value: '0.00')

    assert_includes html, '&lt;img src=x onerror=alert(1)&gt;'
    refute_includes html, '<img'
  end

  test 'atproto client is only returned for calendar event records' do
    create_event
    @organisation.set(atproto_handle: 'org.bsky.social', atproto_app_password: 'password', atproto_did: 'did:plc:org')
    @event.atproto_uri = "at://did:plc:org/#{Event::ATPROTO_COLLECTION}/abc"
    assert @event.atproto_client_for_record
    @event.atproto_uri = 'at://did:plc:org/app.bsky.feed.post/abc'
    assert_nil @event.atproto_client_for_record
  end

  def add_facilitator(event)
    facilitator = FactoryBot.create(:account)
    event.event_facilitations.create!(account: facilitator)
    facilitator
  end

  def connected_account(organisation)
    account = FactoryBot.create(:account)
    account.organisationships.create!(organisation: organisation, stripe_connect_json: { 'stripe_user_id' => "acct_#{account.id}" }.to_json)
    account
  end

  def organisation_admin_pages(organisation)
    {
      'settings' => "/o/#{organisation.slug}/edit",
      'followers' => "/o/#{organisation.slug}/followers",
      'bans' => "/o/#{organisation.slug}/banned_emails",
      'mailer' => "/o/#{organisation.slug}/pmails",
      'orders' => "/o/#{organisation.slug}/orders",
      'discount codes' => "/o/#{organisation.slug}/discount_codes",
      'activities' => "/activities/new?organisation_id=#{organisation.id}",
      'local groups' => "/local_groups/new?organisation_id=#{organisation.id}",
      'carousels' => "/o/#{organisation.slug}/carousels",
      'tiers' => "/o/#{organisation.slug}/tiers",
      'deletion' => "/o/#{organisation.slug}/delete"
    }
  end

  test 'only organisation admins can open the organisation settings, followers, bans, mailer, orders, discount codes, activities, local groups, carousels, tiers and deletion pages' do
    covers 'organisations/event-manager-creates-and-edits-events@3f0102', 'organisations/table-edit-organisation-settings@169353', 'organisations/table-manage-followers-credits-bans@7b2dbd', 'organisations/table-organisation-mailer@64db60', 'organisations/table-organisation-orders-discount-codes@1ea827', 'organisations/table-activities-local-groups-carousels-tiers@49b568', 'organisations/table-delete-organisation@467e21', 'events/facilitator-no-organisation-access@ec2446'
    covers_route 'GET /o/:slug/carousels'
    create_event
    manager = add_event_manager(@organisation)
    facilitator = add_facilitator(@event)

    [manager, facilitator].each do |account|
      sign_in_with_rack(account)
      organisation_admin_pages(@organisation).each do |page, path|
        get path
        assert last_response.redirect?, "#{page} page was open to #{account == manager ? 'an event manager' : 'a facilitator'}"
        assert_includes last_response.location, "/o/#{@organisation.slug}"
      end
    end

    sign_in_with_rack(@account)
    organisation_admin_pages(@organisation).each do |page, path|
      get path
      assert last_response.ok?, "#{page} page was not open to an organisation admin (#{last_response.status})"
    end
  end

  test 'only organisation admins can add or remove admins, grant event manager, give credit or delete the organisation' do
    covers 'organisations/table-manage-followers-credits-bans@7b2dbd', 'organisations/table-add-remove-organisation-admins@a0a094', 'organisations/table-grant-event-manager@4e7638', 'organisations/table-delete-organisation@467e21'
    covers_route 'POST /o/:slug/event_manager/:organisationship_id'
    covers_route 'POST /o/:slug/organisationships/admin'
    covers_route 'POST /o/:slug/organisationships/unadmin'
    covers_route 'POST /organisationships/:id/credit/:plus_or_minus'
    create_event
    manager = add_event_manager(@organisation)
    facilitator = add_facilitator(@event)
    follower = add_member(@organisation)
    followership = @organisation.organisationships.find_by(account: follower)
    other_admin = add_member(@organisation, admin: true)

    [manager, facilitator].each do |account|
      sign_in_with_rack(account)
      post "/o/#{@organisation.slug}/organisationships/admin", organisationship: { account_id: follower.id.to_s }
      post "/o/#{@organisation.slug}/organisationships/unadmin", account_id: other_admin.id.to_s
      post "/o/#{@organisation.slug}/event_manager/#{followership.id}", event_manager: '1'
      post "/organisationships/#{followership.id}/credit/plus", amount: '10'
      post "/o/#{@organisation.slug}/destroy", organisation_name: @organisation.name
    end
    followership.reload
    refute followership.admin
    refute followership.event_manager
    assert_equal 0, followership.creditings.count
    assert Organisation.admin?(@organisation, other_admin)
    assert Organisation.find(@organisation.id)
  end

  test 'organisation admins can add and remove admins, grant event manager and give credit' do
    covers 'organisations/table-manage-followers-credits-bans@7b2dbd', 'organisations/table-add-remove-organisation-admins@a0a094', 'organisations/table-grant-event-manager@4e7638'
    covers_route 'GET /o/:slug/event_manager/:organisationship_id'
    covers_route 'GET /o/:slug/organisationships/admins'
    create_organisation
    follower = add_member(@organisation)
    follower.set(name: 'Fern Follower', has_signed_in: true)
    followership = @organisation.organisationships.find_by(account: follower)
    other_admin = add_member(@organisation, admin: true)
    admins_box = "[data-pagelet-url='/o/#{@organisation.slug}/organisationships/admins']"

    sign_in(@account)
    visit "/o/#{@organisation.slug}"
    within(admins_box) do
      find('.remove-role-toggle').click
      select "#{other_admin.name} (#{other_admin.username})", from: 'account_id'
      click_button_and_confirm 'Remove admin'
    end
    assert page.has_css? "#{admins_box} .add-role-toggle"
    assert page.has_no_css? "#{admins_box} img[alt='#{other_admin.name}']"
    refute Organisation.admin?(@organisation, other_admin)

    visit "/o/#{@organisation.slug}/followers"
    find("#organisationship-event-manager-#{followership.id}").click
    # The switch saves as it's flicked, and its box comes back with it on
    assert page.has_css? "#organisationship-event-manager-#{followership.id}[checked]"
    assert followership.reload.event_manager

    visit "/organisationships/#{followership.id}/credit_balance"
    find('.lead a', match: :first).click
    find('#plus-credit input').send_keys('10', :enter)
    assert page.has_css? '.lead .badge', text: '10'
    assert_equal 1, followership.creditings.count

    visit "/o/#{@organisation.slug}"
    within(admins_box) { find('.add-role-toggle').click }
    choose_in_lookup('organisationship_account_id', follower.name)
    within(admins_box) { click_button 'Add admin' }
    assert page.has_css? "#{admins_box} img[alt='#{follower.name}']"
    assert followership.reload.admin
  end

  test 'event stats are open to organisation admins and event managers but not other event admins' do
    covers 'organisations/table-event-stats@3be66e', 'events/facilitator-no-organisation-access@ec2446'
    create_event
    manager = add_event_manager(@organisation)
    facilitator = add_facilitator(@event)

    [@account, manager].each do |account|
      sign_in_with_rack(account)
      get "/o/#{@organisation.slug}/events/stats"
      assert last_response.ok?
    end

    sign_in_with_rack(facilitator)
    get "/o/#{@organisation.slug}/events/stats"
    assert last_response.redirect?
    assert_includes last_response.location, "/o/#{@organisation.slug}"
  end

  test 'event managers can feature events, change who can see emails and change the revenue sharer and profit shares' do
    covers 'organisations/table-feature-events-show-emails@6842a0', 'organisations/table-change-revenue-sharer@a04837'
    create_event(prices: [0], show_emails: false, featured: false)
    # Revenue sharing, and its tab, comes with Stripe
    @organisation.set(stripe_client_id: 'ca_test')
    manager = add_event_manager(@organisation)
    sharer = connected_account(@organisation)
    sharer.set(name: 'Sasha Sharer', has_signed_in: true)

    sign_in(manager)
    visit "/e/#{@event.slug}/edit"
    find('label[for="event_featured"]').click
    click_link 'Everything else'
    find('label[for="event_show_emails"]').click
    click_link 'Revenue'
    choose_in_lookup('event_revenue_sharer_id', sharer.name)
    fill_in 'event_revenue_share_to_revenue_sharer', with: '50'
    click_button 'Update event'

    assert page.has_content? 'The event was saved'
    @event.reload
    assert @event.show_emails
    assert @event.featured
    assert_equal sharer.id, @event.revenue_sharer_id
    assert_equal 50, @event.revenue_share_to_revenue_sharer

    visit "/e/#{@event.slug}/edit"
    click_link 'Revenue'
    find('#event_revenue_sharer_id + .select2 .select2-selection__clear').click
    fill_in 'event_profit_share_to_organiser', with: '10'
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    assert_equal 10, @event.reload.profit_share_to_organiser
  end

  test "a submitted event's submitter and facilitators cannot publish it" do
    covers 'organisations/community-event-submissions@e06059', 'organisations/table-publish-submitted@1383ec'
    create_organisation(allow_event_submissions: true)
    submitter = add_member(@organisation)
    create_event(locked: true)
    @event.set(account_id: submitter.id)
    facilitator = add_facilitator(@event)

    [submitter, facilitator].each do |account|
      sign_in_with_rack(account)
      post "/e/#{@event.slug}/edit", event: { locked: '0' }
      assert last_response.redirect?, last_response.body
      assert @event.reload.locked?, 'a submitted event was published by an event admin'
    end
  end

  test 'event managers are offered publishing a submitted event, and its submitter and facilitators are not' do
    covers 'organisations/community-event-submissions@e06059', 'organisations/table-publish-submitted@1383ec'
    create_organisation(allow_event_submissions: true)
    submitter = add_member(@organisation)
    create_event(locked: true, prices: [0])
    @event.set(account_id: submitter.id)
    facilitator = add_facilitator(@event)
    manager = add_event_manager(@organisation)

    [submitter, facilitator].each do |account|
      sign_in(account)
      visit "/e/#{@event.slug}/edit"
      assert page.has_content? 'submitted for review'
      assert page.has_no_css? 'label[for="event_locked"]'
    end

    sign_in(manager)
    visit "/e/#{@event.slug}/edit"
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    refute @event.reload.locked?
  end

  test 'any event admin can unlock a locked event unless the organisation takes event submissions' do
    covers 'organisations/table-unlock-locked@ec36f3'
    create_event(locked: true, prices: [0])
    facilitator = add_facilitator(@event)

    sign_in(facilitator)
    visit "/e/#{@event.slug}/edit"
    find('label[for="event_locked"]').click
    click_button 'Update event'
    assert page.has_content? 'The event was saved'
    refute @event.reload.locked?

    @event.set(locked: true)
    @organisation.set(allow_event_submissions: true)
    visit "/e/#{@event.slug}/edit"
    assert page.has_content? 'submitted for review'
    assert page.has_no_css? 'label[for="event_locked"]'
  end

  test 'event admins cannot unlock a locked event once the organisation takes event submissions' do
    covers 'organisations/table-unlock-locked@ec36f3'
    create_organisation(allow_event_submissions: true)
    create_event(locked: true)
    facilitator = add_facilitator(@event)

    sign_in_with_rack(facilitator)
    post "/e/#{@event.slug}/edit", event: { locked: '0' }
    assert last_response.redirect?, last_response.body
    assert @event.reload.locked?
  end

  test 'all event admins can email attendees, check people in and add or remove facilitators' do
    covers 'organisations/who-becomes-event-admin@459b2f', 'organisations/facilitator-listed-emailed-opt-in@29059a', 'organisations/table-email-attendees@b952f3', 'organisations/table-check-in@4b9c7e', 'organisations/table-add-remove-facilitators@c8f92a', 'events/facilitator-no-organisation-access@ec2446'
    covers_route 'GET /e/:slug/check_in_list'
    covers_route 'GET /e/:slug/check_in_toggle/:ticket_id'
    covers_route 'POST /e/:slug/event_facilitations/destroy'
    create_event(prices: [0])
    ticket = @event.tickets.create!(account: FactoryBot.create(:account), ticket_type: @event.ticket_types.first, payment_completed: true)
    facilitator = add_facilitator(@event)
    manager = add_event_manager(@organisation)
    facilitators_box = "[data-pagelet-url='/e/#{@event.slug}/event_facilitations']"

    { 'organisation admin' => @account, 'event manager' => manager, 'facilitator' => facilitator }.each_with_index do |(role, account), i|
      sign_in(account)

      visit "/pmails/new?event_id=#{@event.id}"
      assert page.has_field?('pmail_subject'), "mailer refused a #{role}"

      visit "/e/#{@event.slug}/check_in_list"
      find("#check-in-#{ticket.id}").click
      # The switch saves as it's flicked, and its box comes back with it on
      assert page.has_css?("#check-in-#{ticket.id}[checked]"), "check-in refused a #{role}"
      assert ticket.reload.checked_in
      ticket.set(checked_in: false)

      other = FactoryBot.create(:account, name: "Other Facilitator#{i}", has_signed_in: true)
      visit "/e/#{@event.slug}"
      within(facilitators_box) { find('.add-role-toggle').click }
      choose_in_lookup('event_facilitation_account_id', other.name)
      within(facilitators_box) { click_button 'Add event facilitator' }
      assert page.has_css?("#{facilitators_box} img[alt='#{other.name}']"), "adding a facilitator refused a #{role}"
      assert @event.event_facilitations.find_by(account: other)

      within(facilitators_box) do
        find('.remove-role-toggle').click
        select "#{other.name} (#{other.username})", from: 'account_id'
        click_button_and_confirm 'Remove event facilitator'
      end
      assert page.has_css? "#{facilitators_box} .add-role-toggle"
      assert page.has_no_css?("#{facilitators_box} img[alt='#{other.name}']"), "removing a facilitator refused a #{role}"
      refute @event.event_facilitations.find_by(account: other)
    end
  end

  test 'other event admins see attendee emails once the event allows all event admins to view them' do
    covers 'organisations/table-see-attendee-emails@ae1847', 'organisations/show-emails-lets-event-admins-see-emails@d27542'
    create_event(show_emails: false)
    facilitator = add_facilitator(@event)
    manager = add_event_manager(@organisation)
    assert Event.email_viewer?(@event, @account)
    assert Event.email_viewer?(@event, manager)
    refute Event.email_viewer?(@event, facilitator)

    @event.set(show_emails: true)
    assert Event.email_viewer?(@event.reload, facilitator)
  end

  test 'being set as the revenue sharer, organiser or coordinator makes you an event admin' do
    covers 'organisations/who-becomes-event-admin@459b2f'
    create_event
    sharer = FactoryBot.create(:account)
    organiser = FactoryBot.create(:account)
    coordinator = FactoryBot.create(:account)
    refute Event.admin?(@event, sharer)

    @event.set(revenue_sharer_id: sharer.id, organiser_id: organiser.id, coordinator_id: coordinator.id)
    @event.reload
    [sharer, organiser, coordinator].each { |account| assert Event.admin?(@event, account) }
  end

  test 'facilitators are listed on the event page, emailed about orders and waitlist registrations, offered as an opt-in and listed on the facilitators page once they have feedback' do
    covers 'organisations/facilitator-listed-emailed-opt-in@29059a'
    create_event(prices: [0], send_order_notifications: true, opt_in_facilitator: true)
    @event.event_facilitations.destroy_all
    facilitator = FactoryBot.create(:account, name: 'Fran Facilitator', has_signed_in: true)
    refute(@event.checkout_opt_ins.any? { |opt_in| opt_in[:name] == 'opt_in_facilitator' })
    @event.event_facilitations.create!(account: facilitator)
    @event.reload

    get "/e/#{@event.slug}"
    assert last_response.ok?
    assert_includes last_response.body, %(data-account-username="#{facilitator.username}")

    opt_in = @event.checkout_opt_ins.find { |o| o[:name] == 'opt_in_facilitator' }
    assert_equal 'Get email updates from Fran', opt_in[:label]

    attendee = FactoryBot.create(:account)
    order = @event.orders.create!(account: attendee, value: 0, currency: @event.currency, payment_completed: false)
    email = recorded_email { order.send_notification_without_delay }
    assert_equal [facilitator.email], email.recipients

    waitship = @event.waitships.create!(account: attendee)
    email = recorded_email { waitship.send_notification_without_delay }
    assert_equal [facilitator.email], email.recipients

    @event.set(start_time: 2.days.ago, end_time: 1.day.ago)
    @event.event_feedbacks.create!(account: attendee, rating: 5)
    EventFeedback.update_event_feedbacks_as_facilitator_details
    get '/facilitators'
    assert last_response.ok?
    assert_includes last_response.body, facilitator.username
  end

  test 'activity and local group admins can change the revenue sharer, split and profit shares' do
    covers 'organisations/revenue-fields-activity-local-group-admins@2eb0aa'
    create_full_event_hierarchy
    activity_admin = FactoryBot.create(:account)
    @activity.activityships.create!(account: activity_admin, admin: true, unsubscribed: false)
    local_group_admin = FactoryBot.create(:account)
    @local_group.local_groupships.create!(account: local_group_admin, admin: true, unsubscribed: false)

    [activity_admin, local_group_admin].each do |account|
      event = Event.find(@event.id)
      event.last_saved_by = account
      event.revenue_sharer = connected_account(@organisation)
      event.revenue_share_to_revenue_sharer = 50
      assert event.save, event.errors.full_messages.join(', ')

      event.last_saved_by = account
      event.revenue_sharer = nil
      event.profit_share_to_organiser = 10
      assert event.save, event.errors.full_messages.join(', ')
    end
  end

  test 'other event admins cannot change the revenue sharer, split or profit shares' do
    covers 'organisations/table-change-revenue-sharer@a04837', 'organisations/revenue-fields-activity-local-group-admins@2eb0aa'
    create_event
    cohost = FactoryBot.create(:organisation)
    @event.cohostships.create!(organisation: cohost)
    creator = FactoryBot.create(:account)
    organiser = FactoryBot.create(:account)
    coordinator = FactoryBot.create(:account)
    sharer = connected_account(@organisation)
    @event.set(account_id: creator.id, coordinator_id: coordinator.id)

    { 'creator' => creator, 'organiser' => organiser, 'coordinator' => coordinator, 'revenue sharer' => sharer, 'co-host admin' => cohost.account }.each do |role, account|
      @event.set(organiser_id: (role == 'revenue sharer' ? nil : organiser.id), revenue_sharer_id: (role == 'revenue sharer' ? sharer.id : nil))
      event = Event.find(@event.id)
      assert Event.admin?(event, account), "#{role} is not an event admin"

      event.last_saved_by = account
      if role == 'revenue sharer'
        event.revenue_share_to_revenue_sharer = 100
        refute event.valid?
        assert_includes event.errors[:revenue_share_to_revenue_sharer], '- you cannot change this setting', role
      else
        event.organiser = nil
        event.revenue_sharer = connected_account(@organisation)
        event.revenue_share_to_revenue_sharer = 50
        refute event.valid?
        assert_includes event.errors[:revenue_sharer], '- you cannot change this setting', role
      end

      event = Event.find(@event.id)
      event.last_saved_by = account
      event.profit_share_to_coordinator = 10
      refute event.valid?
      assert_includes event.errors[:profit_share_to_coordinator], '- you cannot change this setting', role
    end
  end

  test 'an event admin who cannot see attendee emails cannot link the event to a gathering they admin' do
    covers 'gatherings/link-gathering-email-viewers@a35f78'
    create_event(show_emails: false)
    facilitator = create_facilitator(@event)
    gathering = FactoryBot.create(:gathering, account: facilitator)
    @event.gathering = gathering
    @event.last_saved_by = facilitator
    refute @event.valid?
    assert_includes @event.errors[:gathering], "- you don't have permission to add attendees to this gathering"

    # Once the organisation lets event admins see emails, they can
    @event.set(show_emails: true)
    assert @event.valid?, @event.errors.full_messages.join(', ')
  end

  test 'a new event cannot turn on show_emails to link a gathering' do
    covers 'gatherings/link-gathering-email-viewers@a35f78'
    create_organisation(allow_event_submissions: true)
    submitter = FactoryBot.create(:account)
    gathering = FactoryBot.create(:gathering, account: submitter)
    event = FactoryBot.build(:event, organisation: @organisation, account: submitter, last_saved_by: submitter, show_emails: true, gathering: gathering)
    refute event.valid?
    assert_includes event.errors[:gathering], "- you don't have permission to add attendees to this gathering"
  end

  test 'organisation and cohost admins can link an event to a gathering they admin' do
    covers 'gatherings/link-gathering-email-viewers@a35f78'
    create_organisation
    gathering = FactoryBot.create(:gathering, account: @account)
    event = FactoryBot.build(:event, organisation: @organisation, account: @account, show_emails: false, gathering: gathering)
    assert event.valid?, event.errors.full_messages.join(', ')

    create_event(show_emails: false)
    @event.gathering = gathering
    @event.last_saved_by = @account
    assert @event.valid?, @event.errors.full_messages.join(', ')

    # And so can an event manager of a cohost
    cohost = FactoryBot.create(:organisation)
    manager = add_event_manager(cohost)
    @event.cohostships.create!(organisation: cohost)
    @event.gathering = FactoryBot.create(:gathering, account: manager)
    @event.last_saved_by = manager
    assert @event.valid?, @event.errors.full_messages.join(', ')
  end

  test 'an event admin who cannot see attendee emails cannot link a gathering by posting its id' do
    covers_route 'POST /e/:slug/edit'
    covers 'gatherings/link-gathering-email-viewers@a35f78'
    create_event(prices: [0], show_emails: false)
    facilitator = create_facilitator(@event)
    gathering = FactoryBot.create(:gathering, account: facilitator)

    sign_in_with_rack(facilitator)
    post "/e/#{@event.slug}/edit", event: { gathering_id: gathering.id }
    refute last_response.redirect?
    assert_nil @event.reload.gathering_id
  end

  test 'only event admins who can see attendee emails are offered the gathering field' do
    covers 'gatherings/link-gathering-email-viewers@a35f78'
    create_event(prices: [0], show_emails: false)
    facilitator = create_facilitator(@event)
    FactoryBot.create(:gathering, account: facilitator, name: 'Facilitator Gathering')
    FactoryBot.create(:gathering, account: @account, name: 'Admin Gathering')

    sign_in(facilitator)
    visit "/e/#{@event.slug}/edit"
    click_link 'Everything else'
    assert page.has_field? 'event_slug'
    assert page.has_no_field? 'event_gathering_id'

    sign_in(@account)
    visit "/e/#{@event.slug}/edit"
    click_link 'Everything else'
    assert page.has_select? 'event_gathering_id', with_options: ['Admin Gathering']
  end
end
