require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'ostruct'

class EventBoostsTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'event admin can view boosts page and pending boost shows checkout ids' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [0])

    login_as(@account)
    visit "/events/#{@event.id}/boosts"

    assert page.has_content?('Boost this event')

    start_time = (Time.zone.now.beginning_of_hour + 2.hours).strftime('%Y-%m-%d %H:%M')
    execute_script %(document.getElementById('event_boost_start_time').value = #{start_time.to_json})
    fill_in 'event_boost_hours', with: 2
    fill_in 'event_boost_hourly_amount', with: 12

    stripe_session = OpenStruct.new(id: 'cs_test_boost', payment_intent: 'pi_test_boost')
    Stripe::Checkout::Session.stub :create, stripe_session do
      page.execute_script(<<~JS)
        window.Stripe = function() { return { redirectToCheckout: function() { return Promise.resolve(); } }; };
      JS
      click_button 'Buy boost'
    end

    event_boost = @event.event_boosts.order('created_at desc').first
    assert_equal 'cs_test_boost', event_boost.session_id
    assert_equal 'pi_test_boost', event_boost.payment_intent
    refute event_boost.payment_completed?
  end

  test 'boost payment can be marked complete' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, prices: [0])

    login_as(@account)
    visit "/events/#{@event.id}/boosts"

    start_time = (Time.zone.now.beginning_of_hour + 2.hours).strftime('%Y-%m-%d %H:%M')
    execute_script %(document.getElementById('event_boost_start_time').value = #{start_time.to_json})
    fill_in 'event_boost_hours', with: 1
    fill_in 'event_boost_hourly_amount', with: 10

    stripe_session = OpenStruct.new(id: 'cs_complete_me', payment_intent: 'pi_test')
    Stripe::Checkout::Session.stub :create, stripe_session do
      page.execute_script(<<~JS)
        window.Stripe = function() { return { redirectToCheckout: function() { return Promise.resolve(); } }; };
      JS
      click_button 'Buy boost'
    end

    event_boost = @event.event_boosts.order('created_at desc').first
    refute event_boost.payment_completed?
    event_boost.set(payment_completed: true)

    assert event_boost.reload.payment_completed?

    visit "/events/#{@event.id}/boosts"

    assert page.has_content?('Upcoming')
  end

  test 'global listing renders boosted slot once on the first page' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event_1 = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, name: 'Spotlight listing event', prices: [0])
    @event_2 = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, name: 'Regular listing event', prices: [0])

    FactoryBot.create(:event_boost,
                      event: @event_1,
                      account: @account,
                      start_time: Time.zone.now.beginning_of_hour,
                      hours: 2,
                      hourly_amount: 10)

    visit "/events?organisation_id=#{@organisation.id}"

    assert page.has_content?('Boosted by')
    assert_equal 1, page.text.scan('Spotlight listing event').length
    assert page.has_content?('Regular listing event')
    assert_equal 1, @event_1.event_boost_impressions.count

    visit "/events?organisation_id=#{@organisation.id}&page=2"
    assert page.has_no_content?('Boosted by')
  end

  test 'public listing ignores incomplete active boosts' do
    @account = FactoryBot.create(:account)
    @organisation_1 = FactoryBot.create(:organisation, account: @account, name: 'Visible Org')
    @organisation_2 = FactoryBot.create(:organisation, account: @account, name: 'Other Org')
    @event_1 = FactoryBot.create(:event, organisation: @organisation_1, account: @account, last_saved_by: @account, name: 'Org one event', prices: [0])
    FactoryBot.create(:event, organisation: @organisation_2, account: @account, last_saved_by: @account, name: 'Org two event', prices: [0])

    FactoryBot.create(:event_boost, :pending_payment,
                      event: @event_1,
                      account: @account,
                      start_time: Time.zone.now.beginning_of_hour,
                      hours: 1,
                      hourly_amount: EventBoost.minimum_hourly_amount(@event_1.currency_or_default))

    visit '/events'

    assert page.has_no_content?('Boosted')
    assert page.has_content?('Org one event')
    assert page.has_content?('Org two event')
  end

  test 'boost slot is not shown on homepage teasers or minimal embeds' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account, name: 'Hidden boost slot event', prices: [0])
    @event.set(has_image: true)

    FactoryBot.create(:event_boost,
                      event: @event,
                      account: @account,
                      start_time: Time.zone.now.beginning_of_hour + 2.hours,
                      hours: 1,
                      hourly_amount: 10)

    visit '/events?home=1&images=1&order=trending'
    assert page.has_no_content?('Boosted')

    visit "/o/#{@organisation.slug}/events?minimal=1"
    assert page.has_no_content?('Boosted')
  end
end
