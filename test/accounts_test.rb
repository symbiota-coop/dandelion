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
    @account = FactoryBot.build_stubbed(:account)
    visit '/accounts/new'
    fill_signup_form(@account)
    assert page.has_content?('Welcome to Dandelion!')
  end

  test 'signing in' do
    @account = FactoryBot.create(:account)
    visit '/accounts/sign_in'
    fill_in 'Email', with: @account.email
    fill_in 'Password', with: @account.password
    click_button 'Sign in'
    assert page.has_content?('Signed in')
  end

  test 'editing profile' do
    @account = FactoryBot.create(:account)
    login_as(@account)
    click_link @account.name
    click_link 'Edit profile'
    fill_in 'Full name', with: (name = FactoryBot.build_stubbed(:account).name)
    click_button 'Save profile'
    assert page.has_content?('Your account was updated successfully')
    assert page.has_content?(name)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # New Account Creation with Context
  # ═══════════════════════════════════════════════════════════════════════════

  test 'signing up with organisation_id' do
    @organisation = FactoryBot.create(:organisation)
    @account = FactoryBot.build_stubbed(:account)

    visit "/accounts/new?organisation_id=#{@organisation.id}"
    fill_signup_form(@account)

    assert_edit_redirect_with_param('organisation_id', @organisation.id)
    created_account = Account.find_by(email: @account.email.downcase)
    assert_associated(@organisation, created_account, :organisationships)
  end

  test 'signing up with activity_id' do
    @activity = FactoryBot.create(:activity)
    @account = FactoryBot.build_stubbed(:account)

    visit "/accounts/new?activity_id=#{@activity.id}"
    fill_signup_form(@account)

    assert_edit_redirect_with_param('activity_id', @activity.id)
    created_account = Account.find_by(email: @account.email.downcase)
    assert_associated(@activity, created_account, :activityships)
    assert_associated(@activity.organisation, created_account, :organisationships)
  end

  test 'signing up with local_group_id' do
    @local_group = FactoryBot.create(:local_group)
    @account = FactoryBot.build_stubbed(:account)

    visit "/accounts/new?local_group_id=#{@local_group.id}"
    fill_signup_form(@account)

    assert_edit_redirect_with_param('local_group_id', @local_group.id)
    created_account = Account.find_by(email: @account.email.downcase)
    assert_associated(@local_group, created_account, :local_groupships)
    assert_associated(@local_group.organisation, created_account, :organisationships)
  end

  test 'signing up with event_id' do
    create_full_event_hierarchy
    @account = FactoryBot.build_stubbed(:account)

    visit "/accounts/new?event_id=#{@event.id}"
    fill_signup_form(@account)

    assert_edit_redirect_with_param('event_id', @event.id)
    created_account = Account.find_by(email: @account.email.downcase)
    assert_associated(@organisation, created_account, :organisationships)
    assert_associated(@activity, created_account, :activityships)
    assert_associated(@local_group, created_account, :local_groupships)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Existing Account Handling (Signup with existing email)
  # ═══════════════════════════════════════════════════════════════════════════

  test 'existing account without context' do
    @existing_account = FactoryBot.create(:account)

    visit '/accounts/new'
    fill_signup_form(FactoryBot.build_stubbed(:account, email: @existing_account.email))

    assert page.has_content?("There's already an account registered under that email address")
    assert_equal '/accounts/sign_in', page.current_path
  end

  test 'existing account with organisation_id' do
    @organisation = FactoryBot.create(:organisation)
    @existing_account = FactoryBot.create(:account)

    visit "/accounts/new?organisation_id=#{@organisation.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: @existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(@organisation, @existing_account, :organisationships)
  end

  test 'existing account with activity_id' do
    @activity = FactoryBot.create(:activity)
    @existing_account = FactoryBot.create(:account)

    visit "/accounts/new?activity_id=#{@activity.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: @existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(@activity, @existing_account, :activityships)
    assert_associated(@activity.organisation, @existing_account, :organisationships)
  end

  test 'existing account with local_group_id' do
    @local_group = FactoryBot.create(:local_group)
    @existing_account = FactoryBot.create(:account)

    visit "/accounts/new?local_group_id=#{@local_group.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: @existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(@local_group, @existing_account, :local_groupships)
    assert_associated(@local_group.organisation, @existing_account, :organisationships)
  end

  test 'existing account with event_id' do
    create_full_event_hierarchy
    @existing_account = FactoryBot.create(:account)

    visit "/accounts/new?event_id=#{@event.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: @existing_account.email))

    assert page.has_content?("OK, you're on the list!")
    assert_associated(@organisation, @existing_account, :organisationships)
    assert_associated(@activity, @existing_account, :activityships)
    assert_associated(@local_group, @existing_account, :local_groupships)
  end

  test 'existing account with event_id resubscribes unsubscribed accounts' do
    create_full_event_hierarchy

    # Create an existing account that's unsubscribed from org, activity, and local_group
    @existing_account = FactoryBot.create(:account)
    @organisation.organisationships.find_or_create_by(account: @existing_account).set_unsubscribed!(true)
    @activity.activityships.find_or_create_by(account: @existing_account).set(unsubscribed: true)
    @local_group.local_groupships.find_or_create_by(account: @existing_account).set(unsubscribed: true)

    # Sign up with event_id (which should resubscribe via associate_with_event!)
    visit "/accounts/new?event_id=#{@event.id}"
    fill_signup_form(FactoryBot.build_stubbed(:account, email: @existing_account.email))

    assert page.has_content?("OK, you're on the list!")

    # Verify they're resubscribed
    assert_equal false, @organisation.organisationships.find_by(account: @existing_account).unsubscribed
    assert_equal false, @activity.activityships.find_by(account: @existing_account).unsubscribed
    assert_equal false, @local_group.local_groupships.find_by(account: @existing_account).unsubscribed
  end
end
