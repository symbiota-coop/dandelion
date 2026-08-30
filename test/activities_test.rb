require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class ActivitiesTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating an activity' do
    create_organisation
    activity = FactoryBot.build_stubbed(:activity)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an activity'
    fill_in 'Name', with: activity.name
    click_button 'Create activity'
    assert page.has_content? 'The activity was created'
  end

  test 'editing an activity' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    login_as(@account)
    visit "/activities/#{activity.id}/edit"
    fill_in 'Name', with: (name = FactoryBot.build_stubbed(:activity).name)
    click_button 'Update activity'
    assert page.has_content? 'The activity was saved'
    assert page.has_content? name
  end

  test 'organisation_id and account_id cannot be reassigned on update' do
    activity = FactoryBot.create(:activity)
    assert_cannot_reassign_organisation_or_account(activity)
  end
end
