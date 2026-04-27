require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventCreatorPermissionsTest < ActiveSupport::TestCase
  include Capybara::DSL

  # ─── Account#organisations_for_creating_events ─────────────────────────────

  test 'organisations_for_creating_events includes org owned by account' do
    owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: owner)
    ids = owner.organisations_for_creating_events.pluck(:id)
    assert_includes ids, org.id
  end

  test 'organisations_for_creating_events includes org when account has event_creator on organisationship' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner)
    other = FactoryBot.create(:account)
    other.organisationships.create!(organisation: org, event_creator: true, unsubscribed: false)
    ids = other.organisations_for_creating_events.pluck(:id)
    assert_includes ids, org.id
  end

  test 'organisations_for_creating_events includes org when account is org admin on organisationship' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner)
    other = FactoryBot.create(:account)
    other.organisationships.create!(organisation: org, admin: true, unsubscribed: false)
    ids = other.organisations_for_creating_events.pluck(:id)
    assert_includes ids, org.id
  end

  test 'organisations_for_creating_events does not include org for plain follower only' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner)
    follower = FactoryBot.create(:account)
    follower.organisationships.create!(organisation: org, unsubscribed: false)
    ids = follower.organisations_for_creating_events.pluck(:id)
    refute_includes ids, org.id
  end

  test 'organisations_for_creating_events includes org from activity admin' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner, slug: "org-act-#{SecureRandom.hex(4)}")
    activity = FactoryBot.create(:activity, organisation: org, account: org_owner, slug: "act-#{SecureRandom.hex(4)}")
    # Factory makes org_owner admin on the activity; use a different account as activity admin
    other = FactoryBot.create(:account)
    activity.activityships.create!(account: other, admin: true, unsubscribed: false)
    ids = other.organisations_for_creating_events.pluck(:id)
    assert_includes ids, org.id
  end

  test 'organisations_for_creating_events includes org from local group admin' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner, slug: "org-lg-#{SecureRandom.hex(4)}")
    local_group = FactoryBot.create(:local_group, organisation: org, account: org_owner, slug: "lg-#{SecureRandom.hex(4)}")
    other = FactoryBot.create(:account)
    local_group.local_groupships.create!(account: other, admin: true, unsubscribed: false)
    ids = other.organisations_for_creating_events.pluck(:id)
    assert_includes ids, org.id
  end

  # ─── Organisation.assistant? ───────────────────────────────────────────────

  test 'assistant? is true for account with event_creator on organisationship' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner)
    other = FactoryBot.create(:account)
    other.organisationships.create!(organisation: org, event_creator: true, unsubscribed: false)
    assert Organisation.assistant?(org, other)
  end

  # ─── Event validation (org-wide, no public submissions) ────────────────────

  test 'event is valid for org-wide create when account has event_creator' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner, allow_event_submissions: false)
    creator = FactoryBot.create(:account)
    creator.organisationships.create!(organisation: org, event_creator: true, unsubscribed: false)
    event = FactoryBot.build(:event, organisation: org, account: creator, last_saved_by: creator, duplicate: false)
    assert event.valid?, event.errors.full_messages.join(', ')
  end

  test 'event is invalid for org-wide create when account is only a follower' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner, allow_event_submissions: false)
    follower = FactoryBot.create(:account)
    follower.organisationships.create!(organisation: org, unsubscribed: false)
    event = FactoryBot.build(:event, organisation: org, account: follower, last_saved_by: follower, duplicate: false)
    refute event.valid?
    assert_includes event.errors[:organisation], "- you don't have permission to create events for this organisation"
  end

  # ─── GET /events/new permission ──────────────────────────────────────────────

  test 'GET /events/new with organisation_id allows event_creator' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner, contribution_not_required: true)
    creator = FactoryBot.create(:account)
    creator.organisationships.create!(organisation: org, event_creator: true, unsubscribed: false)
    login_as(creator)
    visit "/events/new?organisation_id=#{org.id}"
    assert page.has_content?('Event title*')
  end

  test 'GET /events/new with organisation_id redirects for plain follower' do
    org_owner = FactoryBot.create(:account)
    org = FactoryBot.create(:organisation, account: org_owner, contribution_not_required: true)
    follower = FactoryBot.create(:account)
    follower.organisationships.create!(organisation: org, unsubscribed: false)
    login_as(follower)
    visit "/events/new?organisation_id=#{org.id}"
    assert_equal '/events', current_path
    assert page.has_content? "don't have permission to create events for this organisation"
  end
end
