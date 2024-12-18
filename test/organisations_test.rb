require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DandelionTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating an organisation' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.build_stubbed(:organisation)
    login_as(@account)
    click_link 'Organisations'
    click_link 'All organisations'
    click_link 'Create an organisation'
    fill_in 'Organisation name', with: @organisation.name
    fill_in 'URL', with: @organisation.slug
    click_button 'Save and continue'
    assert page.has_content? 'Update organisation'
  end

  test 'editing an organisation' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    login_as(@account)
    visit "/o/#{@organisation.slug}/edit"
    fill_in 'Organisation name', with: (name = FactoryBot.build_stubbed(:organisation).name)
    click_button 'Update organisation'
    assert page.has_content? 'The organisation was saved'
    assert page.has_content? name
  end
end
