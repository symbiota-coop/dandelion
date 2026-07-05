require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class OrganisationsTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating an organisation' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.build_stubbed(:organisation)
    login_as(@account)
    click_link 'Organisations'
    click_link 'All organisations'
    within('#content') { click_link 'Create an organisation' }
    fill_in 'Organisation name', with: @organisation.name
    fill_in 'URL', with: @organisation.slug
    click_button 'Save and continue'
    assert page.has_content? 'To accept payments, now add details for Stripe or another payment processor.'
  end

  test 'editing an organisation' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    login_as(@account)
    visit "/o/#{@organisation.slug}/edit"
    fill_in 'Organisation name', with: FactoryBot.build_stubbed(:organisation).name
    click_button 'Update organisation'
    assert page.has_content? "Now let's create an event under your new organisation."
  end

  test 'referrals page shows short referral link' do
    @account = FactoryBot.create(:account, username: 'linkuser', has_signed_in: true)
    login_as(@account)
    visit '/referrals'
    assert page.has_field?('organisation-referrer-link', with: "#{ENV['BASE_URI']}/invite/#{@account.id}")
  end

  test 'creating an organisation via referral link sets referrer' do
    referrer = FactoryBot.create(:account, username: 'referreruser', has_signed_in: true)
    creator = FactoryBot.create(:account)
    @organisation = FactoryBot.build_stubbed(:organisation)

    login_as(creator)
    visit "/invite/#{referrer.id}"
    fill_in 'Organisation name', with: @organisation.name
    fill_in 'URL', with: @organisation.slug
    click_button 'Save and continue'

    saved_organisation = Organisation.find_by(slug: @organisation.slug)
    assert_equal referrer.id, saved_organisation.referrer_id
  end

  test 'referral link does not self-refer' do
    @account = FactoryBot.create(:account, username: 'selfref', has_signed_in: true)
    @organisation = FactoryBot.build_stubbed(:organisation)

    login_as(@account)
    visit "/invite/#{@account.id}"
    fill_in 'Organisation name', with: @organisation.name
    fill_in 'URL', with: @organisation.slug
    click_button 'Save and continue'

    saved_organisation = Organisation.find_by(slug: @organisation.slug)
    assert_nil saved_organisation.referrer_id
  end

  test 'organisation unsubscribe token resolves account for organisation' do
    @organisation = FactoryBot.create(:organisation)
    @account = FactoryBot.create(:account)
    token = @account.organisation_unsubscribe_token_for(@organisation)

    assert_equal @account, Account.from_organisation_unsubscribe_token(@organisation, token)
  end

  test 'organisation unsubscribe token is scoped to organisation' do
    @organisation = FactoryBot.create(:organisation)
    @other_organisation = FactoryBot.create(:organisation)
    @account = FactoryBot.create(:account)
    token = @account.organisation_unsubscribe_token_for(@organisation)

    assert_nil Account.from_organisation_unsubscribe_token(@other_organisation, token)
  end

  test 'organisation unsubscribe rejects arbitrary account_id' do
    @organisation = FactoryBot.create(:organisation)
    @victim = FactoryBot.create(:account)
    @victim.organisationships.create!(organisation: @organisation)

    visit "/o/#{@organisation.slug}/unsubscribe?account_id=#{@victim.id}"

    assert page.has_current_path?('/accounts/new')
    assert_equal false, @victim.organisationships.find_by(organisation: @organisation).unsubscribed
  end

  test 'organisation unsubscribe via token is two-click' do
    @organisation = FactoryBot.create(:organisation)
    @account = FactoryBot.create(:account, email: 'unsub@example.com')
    organisationship = @account.organisationships.create!(organisation: @organisation)
    token = @account.organisation_unsubscribe_token_for(@organisation)

    visit "/o/#{@organisation.slug}/unsubscribe?token=#{token}"

    assert page.has_content?('Are you sure you want to unsubscribe')
    assert page.has_content?('unsub@example.com')
    click_button 'Yes, unsubscribe'

    assert page.has_content?('was unsubscribed from')
    organisationship.reload
    assert organisationship.unsubscribed
  end

  test 'signed-in organisation unsubscribe redirects to subscriptions' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    organisationship = @account.organisationships.find_by(organisation: @organisation)
    login_as(@account)

    visit "/o/#{@organisation.slug}/unsubscribe"
    click_button 'Yes, unsubscribe'

    assert page.has_current_path?('/accounts/subscriptions')
    organisationship.reload
    assert organisationship.unsubscribed
  end
end
