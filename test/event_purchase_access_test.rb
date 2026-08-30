require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'rack/test'

class EventPurchaseAccessTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def app
    Padrino.application
  end

  def sign_in(account)
    account.generate_sign_in_token!
    get '/', sign_in_token: account.sign_in_token
    follow_redirect! while last_response.redirect?
  end

  def post_purchase(event, account)
    ticket_type = event.ticket_types.first
    header 'Accept', 'application/json'
    post "/events/#{event.id}/purchase",
         ticketForm: { quantities: { ticket_type.id.to_s => '1' } },
         detailsForm: {
           payment_method: 'rsvp',
           account: { name: account.name, email: account.email }
         }
  end

  test 'purchase is forbidden when the event is locked and the buyer cannot view the page' do
    create_full_event_hierarchy(event_options: { prices: [0], locked: true })
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)

    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'purchase is allowed when the event is locked and the buyer is an event admin' do
    create_full_event_hierarchy(event_options: { prices: [0], locked: true })

    sign_in(@org_account)
    post_purchase(@event, @org_account)

    assert_equal 200, last_response.status
    assert @event.orders.find_by(account: @org_account)
  end

  test 'purchase is forbidden when monthly_donors_only and the buyer is not a signed-in donor' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)
    assert_equal 403, last_response.status

    sign_in(buyer)
    post_purchase(@event, buyer)
    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'purchase is allowed when monthly_donors_only and the buyer is a signed-in donor' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })
    buyer = FactoryBot.create(:account)
    FactoryBot.create(:organisationship, organisation: @organisation, account: buyer, monthly_donation_method: 'Other')

    sign_in(buyer)
    post_purchase(@event, buyer)

    assert_equal 200, last_response.status
    assert @event.orders.find_by(account: buyer)
  end

  test 'purchase is forbidden when the activity is closed and the buyer is not a member' do
    create_full_event_hierarchy(event_options: { prices: [0] })
    @activity.set(privacy: 'closed')
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)
    assert_equal 403, last_response.status

    sign_in(buyer)
    post_purchase(@event, buyer)
    assert_equal 403, last_response.status
    assert_equal 0, @event.orders.count
  end

  test 'purchase is allowed when the activity is closed and the buyer is a signed-in member' do
    create_full_event_hierarchy(event_options: { prices: [0] })
    @activity.set(privacy: 'closed')
    buyer = FactoryBot.create(:account)
    @activity.activityships.create!(account: buyer)

    sign_in(buyer)
    post_purchase(@event, buyer)

    assert_equal 200, last_response.status
    assert @event.orders.find_by(account: buyer)
  end

  test 'purchase remains allowed for an open unlocked event' do
    create_full_event_hierarchy(event_options: { prices: [0] })
    buyer = FactoryBot.create(:account)

    post_purchase(@event, buyer)

    assert_equal 200, last_response.status
    assert @event.orders.find_by(account: buyer)
  end

  test 'ticket_form_only does not render the purchase form when the buyer cannot purchase' do
    create_full_event_hierarchy(event_options: { prices: [0], monthly_donors_only: true })

    get "/e/#{@event.slug}", ticket_form_only: 1

    assert_equal 200, last_response.status
    refute_includes last_response.body, 'id="select-tickets"'
    assert_includes last_response.body, 'monthly donor'
  end
end
