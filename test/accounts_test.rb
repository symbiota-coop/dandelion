require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class AccountsTest < ActiveSupport::TestCase
  include Capybara::DSL

  def fill_signup_form(account)
    fill_in 'Full name', with: account.name
    fill_in 'Email', with: account.email
    fill_in 'Location', with: account.location
    click_button 'Sign up'
  end

  def assert_edit_redirect_with_param(param_name, param_value)
    assert page.current_path.include?('/accounts/edit'),
           "Expected redirect to /accounts/edit, got #{page.current_path}"
    assert page.current_url.include?("#{param_name}=#{param_value}"),
           "Expected URL to include #{param_name}=#{param_value}"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Basic Authentication Tests
  # ═══════════════════════════════════════════════════════════════════════════

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

  # ═══════════════════════════════════════════════════════════════════════════
  # New Account Creation with Context
  # ═══════════════════════════════════════════════════════════════════════════

  test 'signing up after visiting referral link returns to organisation creation' do
    referrer = FactoryBot.create(:account, username: 'refsignup', name: 'Signup Referrer', has_signed_in: true)
    account = FactoryBot.build_stubbed(:account)
    organisation = FactoryBot.build_stubbed(:organisation)

    visit "/invite/#{referrer.id}"
    fill_signup_form(account)

    assert page.current_path.include?('/o/new')

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
    account.generate_sign_in_token!
    visit "/e/#{@event2.slug}?sign_in_token=#{account.sign_in_token}"

    assert page.current_path.include?("/e/#{@event2.slug}"),
           "Expected to stay on #{@event2.slug}, got #{page.current_path}"
    refute page.current_path.include?(@event1.slug)
  end

  test 'sign in token on homepage still honours return_to from an event page' do
    create_event
    account = FactoryBot.create(:account)

    visit "/e/#{@event.slug}"
    account.generate_sign_in_token!
    visit "/?sign_in_token=#{account.sign_in_token}"

    assert page.current_path.include?("/e/#{@event.slug}"),
           "Expected to return to #{@event.slug}, got #{page.current_path}"
  end

  test 'return_to is cleared after signup redirect' do
    referrer = FactoryBot.create(:account, username: 'refclear', has_signed_in: true)
    account = FactoryBot.build_stubbed(:account)

    visit "/invite/#{referrer.id}"
    fill_signup_form(account)
    assert page.current_path.include?('/o/new')

    visit '/accounts/sign_out'
    account2 = FactoryBot.build_stubbed(:account)
    visit '/accounts/new'
    fill_signup_form(account2)

    assert page.current_path.include?('/accounts/edit')
    refute page.current_path.include?('/o/new')
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
    activity = FactoryBot.create(:activity, organisation: @organisation)
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

  # ═══════════════════════════════════════════════════════════════════════════
  # Existing Account Handling (Signup with existing email)
  # ═══════════════════════════════════════════════════════════════════════════

  test 'existing account without context' do
    existing_account = FactoryBot.create(:account)

    visit '/accounts/new'
    fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

    assert page.has_content?("There's already an account registered under that email address")
    assert_equal '/accounts/sign_in', page.current_path
  end

  test 'existing account with organisation_id' do
    create_organisation
    existing_account = FactoryBot.create(:account)

    visit "/accounts/new?organisation_id=#{@organisation.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(@organisation, existing_account, :organisationships)
  end

  test 'existing account with activity_id' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    existing_account = FactoryBot.create(:account)

    visit "/accounts/new?activity_id=#{activity.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(activity, existing_account, :activityships)
    assert_associated(@organisation, existing_account, :organisationships)
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

    # Verify they're resubscribed
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
end
