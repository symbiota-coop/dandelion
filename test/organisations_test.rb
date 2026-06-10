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
end
