require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'rack/test'

class TicketholderEditTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def app
    Padrino.application
  end

  # Rack::Test has no Capybara session; stub the screenshot helper that test_config teardown calls.
  def save_screenshot(*); end

  def setup
    super
    @organiser = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @organiser)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @organiser, last_saved_by: @organiser, prices: [0])
    @event.ticket_types.first.set(quantity: 10)
    @buyer = FactoryBot.create(:account)
    @order = @event.orders.create!(account: @buyer, currency: @event.currency, payment_completed: true)
    @ticket = @order.tickets.create!(event: @event, account: @buyer, ticket_type: @event.ticket_types.first, price: 0)
    @name_path = "/events/#{@event.id}/orders/#{@order.id}/ticketholders/#{@ticket.id}/name"
    @email_path = "/events/#{@event.id}/orders/#{@order.id}/ticketholders/#{@ticket.id}/email"
  end

  def sign_in(account)
    account.generate_sign_in_token!
    get "/?sign_in_token=#{account.sign_in_token}"
  end

  def checkout_as_guest
    post "/events/#{@event.id}/purchase",
         detailsForm: {
           account: { name: 'Guest Buyer', email: "guest-#{SecureRandom.hex(4)}@#{ENV['DOMAIN']}" }
         },
         ticketForm: {
           quantities: { @event.ticket_types.first.id.to_s => 1 }
         }
    assert_equal 200, last_response.status, last_response.body
    payload = JSON.parse(last_response.body)
    order = @event.orders.find(payload['order_id'])
    ticket = order.tickets.first
    [order, ticket]
  end

  test 'guest cannot get or post ticketholder fields without a checkout session' do
    get @name_path
    assert_equal 403, last_response.status

    post @name_path, name: 'Ada Lovelace'
    assert_equal 403, last_response.status
    assert_nil @ticket.reload.name
  end

  test 'guest can edit ticketholder details after checkout in the same browser' do
    order, ticket = checkout_as_guest
    name_path = "/events/#{@event.id}/orders/#{order.id}/ticketholders/#{ticket.id}/name"
    email_path = "/events/#{@event.id}/orders/#{order.id}/ticketholders/#{ticket.id}/email"

    get name_path
    assert_equal 200, last_response.status

    post name_path, name: 'Ada Lovelace'
    assert_equal 200, last_response.status
    assert_equal 'Ada Lovelace', ticket.reload.name

    post email_path, email: 'ada@example.com'
    assert_equal 200, last_response.status
    assert_equal 'ada@example.com', ticket.reload.email
  end

  test 'guest checkout session does not grant access to another order' do
    checkout_as_guest
    post @name_path, name: 'Intruder'
    assert_equal 403, last_response.status
    assert_nil @ticket.reload.name
  end

  test 'purchaser can edit while signed in' do
    sign_in(@buyer)
    post @name_path, name: 'Buyer Name'
    assert_equal 200, last_response.status
    assert_equal 'Buyer Name', @ticket.reload.name
  end

  test 'event admin can edit while signed in' do
    sign_in(@organiser)
    post @name_path, name: 'Admin Name'
    assert_equal 200, last_response.status
    assert_equal 'Admin Name', @ticket.reload.name
  end

  test 'another signed-in account cannot edit' do
    sign_in(FactoryBot.create(:account))
    post @name_path, name: 'Stranger'
    assert_equal 403, last_response.status
    assert_nil @ticket.reload.name
  end

  test 'event page shows ticketholder forms after guest checkout' do
    order, = checkout_as_guest
    get "/e/#{@event.slug}", order_id: order.id
    assert_equal 200, last_response.status
    assert_includes last_response.body, '/ticketholders/'
  end

  test 'event page hides ticketholder forms for a guest with only the order id' do
    get "/e/#{@event.slug}", order_id: @order.id
    assert_equal 200, last_response.status
    refute_includes last_response.body, '/ticketholders/'
  end

  test 'event page shows ticketholder forms for a signed-in purchaser' do
    sign_in(@buyer)
    get "/e/#{@event.slug}", order_id: @order.id
    assert_equal 200, last_response.status
    assert_includes last_response.body, '/ticketholders/'
  end

  test 'order confirmation page does not include a sign-in ticketholder link' do
    @organisation.set(show_ticketholder_link_in_ticket_emails: true)
    get "/orders/#{@order.id}"
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'Visit this page to add details of ticketholders'
  end

  test 'ticket email includes a sign-in link for ticketholder details' do
    @organisation.set(show_ticketholder_link_in_ticket_emails: true)
    @event.reload
    html = EmailHelper.render(
      :tickets,
      event: @event,
      order: @order,
      account: @buyer,
      tickets_table: ''
    )
    assert_includes html, 'Visit this page to add details of ticketholders'
    assert_includes html, "order_id=#{@order.id}"
    assert_includes html, 'sign_in_token=%recipient.token%'
  end
end
