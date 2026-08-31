require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class TourTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'home tour' do
    account = FactoryBot.create(:account)
    sign_in(account)
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
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/edit?tour=1"
    assert page.has_content? "You've created your first organisation"
    execute_script %{$('.introjs-nextbutton').click()}
    assert page.has_content? "Here's the admin dropdown for the organisation"
    execute_script %{$('.introjs-nextbutton').click()}
    assert page.has_content? 'To accept payments, now add details for Stripe or another payment processor.'
  end

  test 'event tour' do
    create_event
    sign_in(@account)
    visit "/events/#{@event.id}?tour=1"
    assert page.has_content? "You've created your first event"
    execute_script %{$('.introjs-nextbutton').click()}
    assert page.has_content? "Here's the admin dropdown for the event"
  end
end
