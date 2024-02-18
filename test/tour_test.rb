require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class CoreTest < ActiveSupport::TestCase
  include Capybara::DSL

  setup do
    reset!
  end

  teardown do
    save_screenshot unless ENV['CI']
  end

  test 'home tour' do
    @account = FactoryBot.create(:account)
    login_as(@account)
    visit '/?tour=1'
    assert page.has_content? 'Welcome to Dandelion!'
    execute_script %{$('.introjs-nextbutton').click()}
    assert page.has_content? "Here's the newsfeed"
    execute_script %{$('.introjs-nextbutton').click()}
    assert page.has_content? "Here's where you'll see your upcoming events"
    execute_script %{$('.introjs-nextbutton').click()}
    assert page.has_content? 'Time to find your first event!'
  end

  test 'organisation tour' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    login_as(@account)
    visit "/o/#{@organisation.slug}/edit?tour=1"
    assert page.has_content? "You've created your first organisation"
    execute_script %{$('.introjs-nextbutton').click()}
    assert page.has_content? "Here's the admin dropdown for the organisation"
    execute_script %{$('.introjs-nextbutton').click()}
    assert page.has_content? 'To accept payments, now add your Stripe and/or Coinbase Commerce details.'
  end

  test 'event tour' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account)
    login_as(@account)
    visit "/events/#{@event.id}?tour=1"
    assert page.has_content? "You've created your first event"
    execute_script %{$('.introjs-nextbutton').click()}
    assert page.has_content? "Here's the admin dropdown for the event"
  end
end
