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
end
