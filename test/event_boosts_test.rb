require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'ostruct'

class EventBoostsTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'event admin can view boosts page and pending boost shows checkout ids' do
    create_event(prices: [0])

    sign_in(@account)
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
    create_event(prices: [0])

    sign_in(@account)
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
    create_event(as: :event1, name: 'Spotlight listing event', prices: [0])
    create_event(as: :event2, name: 'Regular listing event', prices: [0])

    FactoryBot.create(:event_boost,
                      event: @event1,
                      account: @account,
                      start_time: Time.zone.now.beginning_of_hour,
                      hours: 2,
                      hourly_amount: 10)

    visit "/events?organisation_id=#{@organisation.id}"

    assert page.has_content?('Boosted by')
    assert_equal 1, page.text.scan('Spotlight listing event').length
    assert page.has_content?('Regular listing event')
    assert_equal 1, @event1.event_boost_impressions.count

    visit "/events?organisation_id=#{@organisation.id}&page=2"
    assert page.has_no_content?('Boosted by')
  end

  test 'public listing ignores incomplete active boosts' do
    account = FactoryBot.create(:account)
    organisation1 = FactoryBot.create(:organisation, account: account, name: 'Visible Org')
    organisation2 = FactoryBot.create(:organisation, account: account, name: 'Other Org')
    event1 = FactoryBot.create(:event, organisation: organisation1, name: 'Org one event', prices: [0])
    FactoryBot.create(:event, organisation: organisation2, name: 'Org two event', prices: [0])

    FactoryBot.create(:event_boost, :pending_payment,
                      event: event1,
                      account: account,
                      start_time: Time.zone.now.beginning_of_hour,
                      hours: 1,
                      hourly_amount: EventBoost.minimum_hourly_amount(event1.currency_or_default))

    visit '/events'

    assert page.has_no_content?('Boosted')
    assert page.has_content?('Org one event')
    assert page.has_content?('Org two event')
  end

  test 'boost slot is not shown on homepage teasers or minimal embeds' do
    create_event(name: 'Hidden boost slot event', prices: [0])
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

  test 'boosted unpaid event appears in the boost slot but not the regular listing' do
    create_organisation
    @organisation.set(paid_up: false)
    create_event(name: 'Promotion-only boosted event')
    @event.set_browsable
    refute @event.reload.browsable?

    FactoryBot.create(:event_boost,
                      event: @event,
                      account: @account,
                      start_time: Time.zone.now.beginning_of_hour,
                      hours: 2,
                      hourly_amount: 10)

    visit "/events?organisation_id=#{@organisation.id}"

    assert page.has_content?('Boosted by')
    assert page.has_content?('Promotion-only boosted event')
    assert_equal 1, page.text.scan('Promotion-only boosted event').length
    assert_equal 1, @event.event_boost_impressions.count
  end
end
