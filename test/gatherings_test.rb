require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class CoreTest < ActiveSupport::TestCase
  include Capybara::DSL

  setup do
    reset!
  end

  teardown do
    save_screenshot unless ENV['CI']
  end

  test 'creating a gathering' do
    @account = FactoryBot.create(:account)
    @gathering = FactoryBot.build_stubbed(:gathering)
    login_as(@account)
    click_link 'Gatherings'
    click_link 'All gatherings'
    click_link 'Create a gathering'
    fill_in 'Name', with: @gathering.name
    fill_in 'Slug', with: @gathering.slug
    click_link 'Next'
    click_link 'Next'
    click_link 'Next'
    click_link 'Next'
    click_button 'Create gathering'
    assert page.has_content? 'created the gathering'
  end

  test 'editing a gathering' do
    @account = FactoryBot.create(:account)
    @gathering = FactoryBot.create(:gathering, account: @account)
    login_as(@account)
    visit "/g/#{@gathering.slug}/edit"
    fill_in 'Name', with: (name = FactoryBot.build_stubbed(:gathering).name)
    click_button 'Update gathering'
    assert page.has_content? 'The gathering was saved'
    assert page.has_content? name
  end
end
