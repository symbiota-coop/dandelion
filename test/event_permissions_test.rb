require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventPermissionsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def add_member(org, **attrs)
    account = FactoryBot.create(:account)
    account.organisationships.create!(organisation: org, unsubscribed: false, **attrs)
    account
  end

  def add_event_manager(org)
    add_member(org, event_manager: true)
  end

  test 'organisations_for_creating_events includes org when account has event_manager on organisationship' do
    org = FactoryBot.create(:organisation)
    other = add_event_manager(org)
    assert_includes other.organisations_for_creating_events.pluck(:id), org.id
  end

  test 'organisations_for_creating_events includes org when account is org admin on organisationship' do
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
    org = FactoryBot.create(:organisation, allow_event_submissions: false)
    manager = add_event_manager(org)
    event = FactoryBot.build(:event, organisation: org, account: manager, last_saved_by: manager, duplicate: false)
    assert event.valid?, event.errors.full_messages.join(', ')
  end

  test 'event_manager is event admin for organisation event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org)
    assert Event.admin?(event, manager)
  end

  test 'event_manager is event admin for cohosted event' do
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
    post "/events/#{@event.id}/cohostships/new", cohostship: { organisation_id: attacker_org.id }

    assert last_response.redirect?
    assert_includes last_response.location, "/e/#{@event.slug}"
    refute @event.cohostships.find_by(organisation: attacker_org)
    refute Event.admin?(@event.reload, attacker)
  end

  test 'event admin can add an unrestricted org as cohost' do
    create_event
    cohost = FactoryBot.create(:organisation)

    sign_in_with_rack(@account)
    post "/events/#{@event.id}/cohostships/new", cohostship: { organisation_id: cohost.id }

    assert last_response.redirect?
    assert @event.cohostships.find_by(organisation: cohost)
  end

  test 'event admin cannot add a restricted org they do not admin' do
    create_event
    restricted = FactoryBot.create(:organisation, restrict_cohosting: true)

    sign_in_with_rack(@account)
    post "/events/#{@event.id}/cohostships/new", cohostship: { organisation_id: restricted.id }

    assert last_response.redirect?
    assert_includes last_response.location, "/o/#{restricted.slug}"
    refute @event.cohostships.find_by(organisation: restricted)
  end

  test 'event admin can add a restricted org they also admin' do
    create_event
    restricted = FactoryBot.create(:organisation, restrict_cohosting: true)
    restricted.organisationships.create!(account: @account, admin: true)

    sign_in_with_rack(@account)
    post "/events/#{@event.id}/cohostships/new", cohostship: { organisation_id: restricted.id }

    assert last_response.redirect?
    assert @event.cohostships.find_by(organisation: restricted)
  end

  test 'event_manager is email viewer when show_emails is false' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, show_emails: false)
    assert Event.email_viewer?(event, manager)
  end

  test 'cohost event_manager is email viewer when show_emails is false' do
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
    org = FactoryBot.create(:organisation, contribution_not_required: true)
    manager = add_event_manager(org)
    sign_in(manager)
    visit "/events/new?organisation_id=#{org.id}"
    assert page.has_content?('Event title*')
  end

  test 'GET /events/new with organisation_id redirects for plain follower' do
    org = FactoryBot.create(:organisation, contribution_not_required: true)
    follower = add_member(org)
    sign_in(follower)
    visit "/events/new?organisation_id=#{org.id}"
    assert_equal '/events', current_path
    assert page.has_content? "don't have permission to create events for this organisation"
  end

  test 'org event manager can delete their own event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, account: manager, last_saved_by: manager)
    sign_in(manager)
    visit "/events/#{event.id}/delete"
    accept_confirm do
      click_link 'Delete event and attempt to refund all orders'
    end
    assert_equal "/o/#{org.slug}/events", current_path
    assert page.has_content?('The event was deleted')
    assert event.reload.deleted?
  end

  test 'org event manager cannot delete another account event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org)
    sign_in(manager)
    visit "/events/#{event.id}/delete"
    assert page.has_content?("Please ask an admin of #{org.name} to delete the event")
    refute page.has_link?('Delete event and attempt to refund all orders')
    refute event.reload.deleted?
  end

  test 'org admin can delete any organisation event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, account: manager, last_saved_by: manager)
    sign_in(org.account)
    visit "/events/#{event.id}/delete"
    accept_confirm do
      click_link 'Delete event and attempt to refund all orders'
    end
    assert_equal "/o/#{org.slug}/events", current_path
    assert event.reload.deleted?
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
      if event_params.keys.intersect?(%i[last_saved_by_id duplicate])
        error = assert_raises(RuntimeError) { post "/e/#{@event.slug}/edit", event: event_params }
        assert_match(/are protected/, error.message)
      else
        post "/e/#{@event.slug}/edit", event: event_params
        refute last_response.redirect?
      end
      @event.reload
      refute @event.show_emails, "show_emails changed for #{event_params.keys}"
      refute @event.featured, "featured changed for #{event_params.keys}"
    end
  end

  test 'event facilitator cannot change revenue share fields' do
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
      if event_params.keys.intersect?(%i[last_saved_by_id duplicate])
        error = assert_raises(RuntimeError) { post "/e/#{@event.slug}/edit", event: event_params }
        assert_match(/are protected/, error.message)
      else
        post "/e/#{@event.slug}/edit", event: event_params
        refute last_response.redirect?
      end
      @event.reload
      assert_nil @event.revenue_sharer_id, "revenue_sharer set for #{event_params.keys}"
      assert_equal 0, @event.revenue_share_to_revenue_sharer
      assert_equal 0, @event.profit_share_to_organiser
      assert_equal 0, @event.stripe_revenue_adjustment
    end

    post "/e/#{@event.slug}/edit", event: { name: 'Still editable' }
    assert last_response.redirect?
    assert_equal 'Still editable', @event.reload.name
  end

  test 'cohost admin cannot change revenue share fields by adding their own organisation as cohost' do
    create_organisation(stripe_client_id: 'ca_test')
    create_event(prices: [0])
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    facilitator.organisationships.create!(
      organisation: @organisation,
      stripe_connect_json: { 'stripe_user_id' => 'acct_facilitator' }.to_json
    )
    attacker_organisation = FactoryBot.create(:organisation, account: facilitator)

    sign_in_with_rack(facilitator)
    post "/events/#{@event.id}/cohostships/new", cohostship: { organisation_id: attacker_organisation.id.to_s }
    assert @event.cohostships.find_by(organisation: attacker_organisation)
    assert Event.revenue_admin?(@event.reload, facilitator)
    refute Event.revenue_settings_admin?(@event, facilitator)

    post "/e/#{@event.slug}/edit", event: {
      organiser_id: '',
      revenue_sharer_id: facilitator.id.to_s,
      revenue_share_to_revenue_sharer: '100'
    }

    refute last_response.redirect?
    @event.reload
    assert_nil @event.revenue_sharer_id
    assert_equal 0, @event.revenue_share_to_revenue_sharer
  end

  test 'organisation admin can change revenue share fields' do
    create_organisation(stripe_client_id: 'ca_test')
    create_event(prices: [0])
    sharer = FactoryBot.create(:account)
    sharer.organisationships.create!(
      organisation: @organisation,
      stripe_connect_json: { 'stripe_user_id' => 'acct_sharer' }.to_json
    )

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/edit", event: {
      organiser_id: '',
      revenue_sharer_id: sharer.id.to_s,
      revenue_share_to_revenue_sharer: '100'
    }

    assert last_response.redirect?, last_response.body
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
    create_event(prices: [0], show_emails: false, featured: false)

    sign_in_with_rack(@account)
    post "/e/#{@event.slug}/edit", event: { show_emails: '1', featured: '1' }

    assert last_response.redirect?
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
end
