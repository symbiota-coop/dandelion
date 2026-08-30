require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventManagerPermissionsTest < ActiveSupport::TestCase
  include Capybara::DSL

  def add_member(org, **attrs)
    account = FactoryBot.create(:account)
    account.organisationships.create!(organisation: org, unsubscribed: false, **attrs)
    account
  end

  def add_event_manager(org)
    add_member(org, event_manager: true)
  end

  # ─── Account#organisations_for_creating_events ─────────────────────────────

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

  # ─── Organisation.can_create_events_for_organisation? ───────────────────────

  test 'can_create_events_for_organisation? is false for unrelated activity admin' do
    org = FactoryBot.create(:organisation)
    other_org = FactoryBot.create(:organisation, account: org.account)
    activity = FactoryBot.create(:activity, organisation: other_org)
    other = FactoryBot.create(:account)
    activity.activityships.create!(account: other, admin: true, unsubscribed: false)
    refute Organisation.can_create_events_for_organisation?(org, other)
  end

  # ─── Event validation (org-wide, no public submissions) ────────────────────

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

  # ─── GET /events/new permission ──────────────────────────────────────────────

  test 'GET /events/new with organisation_id allows event_manager' do
    org = FactoryBot.create(:organisation, contribution_not_required: true)
    manager = add_event_manager(org)
    login_as(manager)
    visit "/events/new?organisation_id=#{org.id}"
    assert page.has_content?('Event title*')
  end

  test 'GET /events/new with organisation_id redirects for plain follower' do
    org = FactoryBot.create(:organisation, contribution_not_required: true)
    follower = add_member(org)
    login_as(follower)
    visit "/events/new?organisation_id=#{org.id}"
    assert_equal '/events', current_path
    assert page.has_content? "don't have permission to create events for this organisation"
  end

  # ─── Event delete authorization ────────────────────────────────────────────

  test 'org event manager can delete their own event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, account: manager, last_saved_by: manager)
    login_as(manager)
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
    login_as(manager)
    visit "/events/#{event.id}/delete"
    assert page.has_content?("Please ask an admin of #{org.name} to delete the event")
    refute page.has_link?('Delete event and attempt to refund all orders')
    refute event.reload.deleted?
  end

  test 'org admin can delete any organisation event' do
    org = FactoryBot.create(:organisation)
    manager = add_event_manager(org)
    event = FactoryBot.create(:event, organisation: org, account: manager, last_saved_by: manager)
    login_as(org.account)
    visit "/events/#{event.id}/delete"
    accept_confirm do
      click_link 'Delete event and attempt to refund all orders'
    end
    assert_equal "/o/#{org.slug}/events", current_path
    assert event.reload.deleted?
  end
end
