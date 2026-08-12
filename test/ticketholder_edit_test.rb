require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'rack/test'

class TicketholderEditTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def app
    Padrino.application
  end

  def save_screenshot(*); end

  def setup
    super
    @organiser = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @organiser)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @organiser, last_saved_by: @organiser, prices: [0])
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

  test 'guest cannot get or post ticketholder fields without a token' do
    get @name_path
    assert_equal 403, last_response.status

    post @name_path, name: 'Ada Lovelace'
    assert_equal 403, last_response.status
    assert_nil @ticket.reload.name
  end

  test 'guest can edit ticketholder name and email with a valid token' do
    token = @order.ticketholder_edit_token
    assert token.present?

    get @name_path, token: token
    assert_equal 200, last_response.status

    post @name_path, name: 'Ada Lovelace', token: token
    assert_equal 200, last_response.status
    assert_equal 'Ada Lovelace', @ticket.reload.name

    post @email_path, email: 'ada@example.com', token: token
    assert_equal 200, last_response.status
    assert_equal 'ada@example.com', @ticket.reload.email
  end

  test 'guest cannot edit with another order token' do
    other_order = @event.orders.create!(account: FactoryBot.create(:account), currency: @event.currency, payment_completed: true)
    post @name_path, name: 'Intruder', token: other_order.ticketholder_edit_token
    assert_equal 403, last_response.status
    assert_nil @ticket.reload.name
  end

  test 'purchaser can edit while signed in without a token' do
    sign_in(@buyer)
    post @name_path, name: 'Buyer Name'
    assert_equal 200, last_response.status
    assert_equal 'Buyer Name', @ticket.reload.name
  end

  test 'event admin can edit while signed in without a token' do
    sign_in(@organiser)
    post @name_path, name: 'Admin Name'
    assert_equal 200, last_response.status
    assert_equal 'Admin Name', @ticket.reload.name
  end

  test 'another signed-in account cannot edit without a token' do
    sign_in(FactoryBot.create(:account))
    post @name_path, name: 'Stranger'
    assert_equal 403, last_response.status
    assert_nil @ticket.reload.name
  end

  test 'event page shows ticketholder forms for a guest with a token' do
    get "/e/#{@event.slug}", order_id: @order.id, token: @order.ticketholder_edit_token
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'ticketholders'
    assert_includes last_response.body, 'token='
  end

  test 'event page hides ticketholder forms for a guest with only the order id' do
    get "/e/#{@event.slug}", order_id: @order.id
    assert_equal 200, last_response.status
    refute_includes last_response.body, '/ticketholders/'
  end
end
