require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DandelionTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'creating a local group' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @local_group = FactoryBot.build_stubbed(:local_group)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create a local group'
    fill_in 'Name', with: @local_group.name
    fill_in 'Geometry', with: @local_group.geometry
    click_button 'Create local group'
    assert page.has_content? 'The local group was created'
  end

  test 'editing a local group' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @local_group = FactoryBot.create(:local_group, organisation: @organisation, account: @account)
    login_as(@account)
    visit "/local_groups/#{@local_group.id}/edit"
    fill_in 'Name', with: (name = FactoryBot.build_stubbed(:local_group).name)
    click_button 'Update local group'
    assert page.has_content? 'The local group was saved'
    assert page.has_content? name
  end
end
