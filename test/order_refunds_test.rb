require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'ostruct'

class OrderRefundsTest < ActiveSupport::TestCase
  include Capybara::DSL

  def create_event
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, prices: [10])
  end

  def create_paid_order(event)
    Order.create!(
      event: event,
      account: FactoryBot.create(:account),
      value: 10,
      payment_completed: true,
      payment_intent: "pi_#{SecureRandom.hex(8)}",
      currency: event.currency
    )
  end

  def with_stubbed_stripe_refunds
    refunds = []
    payment_intent = OpenStruct.new(charges: [OpenStruct.new(id: 'ch_test')])
    Stripe::PaymentIntent.stub :retrieve, payment_intent do
      Stripe::Refund.stub :create, proc { refunds << true } do
        yield refunds
      end
    end
  end

  test 'destroying an order refunds it' do
    order = create_paid_order(create_event)
    with_stubbed_stripe_refunds do |refunds|
      order.destroy
      assert_equal 1, refunds.size
    end
  end

  test 'destroying an event refunds its orders' do
    event = create_event
    create_paid_order(event)
    with_stubbed_stripe_refunds do |refunds|
      event.destroy
      assert_equal 1, refunds.size
    end
  end

  test 'destroying an event with prevent_order_refunds does not refund orders' do
    event = create_event
    create_paid_order(event)
    event.prevent_order_refunds = true
    with_stubbed_stripe_refunds do |refunds|
      event.destroy
      assert_empty refunds
    end
  end

  test 'connect refunds pass the connected account in request options' do
    event = create_event
    event.organisation.set(stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json)
    order = create_paid_order(event)
    captured_opts = nil
    payment_intent = OpenStruct.new(charges: [OpenStruct.new(id: 'ch_test')])
    Stripe::PaymentIntent.stub :retrieve, payment_intent do
      Stripe::Refund.stub :create, proc { |_params, opts| captured_opts = opts } do
        order.destroy
      end
    end
    assert_equal 'acct_connect', captured_opts[:stripe_account]
    assert_equal ENV['STRIPE_SK'], captured_opts[:api_key]
  end
end
