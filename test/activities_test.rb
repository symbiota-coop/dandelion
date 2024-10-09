require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DandelionTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating an activity' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @activity = FactoryBot.build_stubbed(:activity)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an activity'
    fill_in 'Name', with: @activity.name
    click_button 'Create activity'
    assert page.has_content? 'The activity was created'
  end

  test 'editing an activity' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @activity = FactoryBot.create(:activity, organisation: @organisation, account: @account)
    login_as(@account)
    visit "/activities/#{@activity.id}/edit"
    fill_in 'Name', with: (name = FactoryBot.build_stubbed(:activity).name)
    click_button 'Update activity'
    assert page.has_content? 'The activity was saved'
    assert page.has_content? name
  end
end
