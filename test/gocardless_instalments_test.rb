require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'ostruct'

class GoCardlessInstalmentsTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'split_amounts_in_pence divides evenly when possible' do
    assert_equal [2500, 2500, 2500, 2500], EventPaymentMethod::GoCardlessInstalments.split_amounts_in_pence(100, 4)
  end

  test 'split_amounts_in_pence puts remainder on the last instalment' do
    assert_equal [333, 333, 334], EventPaymentMethod::GoCardlessInstalments.split_amounts_in_pence(10, 3)
  end

  test 'gocardless_instalments payment method is available when enabled' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(
      :organisation,
      account: account,
      gocardless_access_token: 'sandbox_token',
      gocardless_endpoint_secret: 'whsec_test',
      gocardless_instalments: true,
      gocardless_instalment_count: 3
    )
    event = FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, currency: 'GBP')

    pm = EventPaymentMethod.object('gocardless_instalments')
    assert pm
    assert pm.available?(event)
  end

  test 'gocardless_instalments payment method is unavailable when disabled' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account, gocardless_access_token: 'sandbox_token')
    event = FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, currency: 'GBP')

    refute EventPaymentMethod.object('gocardless_instalments').available?(event)
  end

  test 'organisation defaults instalment count and validates range' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.build(
      :organisation,
      account: account,
      gocardless_access_token: 'sandbox_token',
      gocardless_endpoint_secret: 'whsec_test',
      gocardless_instalments: true,
      gocardless_instalment_count: nil
    )
    assert organisation.valid?
    assert_equal 3, organisation.gocardless_instalment_count

    organisation.gocardless_instalment_count = 1
    refute organisation.valid?
    assert_includes organisation.errors[:gocardless_instalment_count], 'must be between 2 and 12'
  end

  test 'record_gocardless_instalment_payment! completes order when paid in full' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    event = FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, currency: 'GBP')
    order = event.orders.create!(
      account: account,
      currency: 'GBP',
      value: 30,
      amount_demanded: 30,
      amount_paid: 0,
      instalment_count: 3,
      gocardless_billing_request_id: 'BRQ123',
      gocardless_instalment_schedule_id: 'IS123',
      payment_completed: false,
      original_description: 'Test order'
    )
    order.tickets.create!(event: event, account: account, price: 30, payment_completed: false)

    notifications = []
    order.stub :send_tickets, -> { notifications << :tickets } do
      order.stub :create_order_notification, -> { notifications << :notification } do
        order.record_gocardless_instalment_payment!(payment_id: 'PM1', amount_major: 10)
        order.record_gocardless_instalment_payment!(payment_id: 'PM2', amount_major: 10)
        refute order.reload.payment_completed?

        order.record_gocardless_instalment_payment!(payment_id: 'PM3', amount_major: 10)
      end
    end

    order.reload
    assert order.payment_completed?
    assert_equal 30, order.amount_paid
    assert_equal %w[PM1 PM2 PM3], order.gocardless_payment_ids
    assert_includes notifications, :tickets
    assert_includes notifications, :notification
    assert order.tickets.first.payment_completed?
  end

  test 'record_gocardless_instalment_payment! is idempotent for the same payment id' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    event = FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, currency: 'GBP')
    order = event.orders.create!(
      account: account,
      currency: 'GBP',
      value: 20,
      amount_demanded: 20,
      amount_paid: 0,
      instalment_count: 2,
      gocardless_billing_request_id: 'BRQ456',
      gocardless_instalment_schedule_id: 'IS456',
      payment_completed: false,
      original_description: 'Test order'
    )

    order.record_gocardless_instalment_payment!(payment_id: 'PM1', amount_major: 10)
    order.record_gocardless_instalment_payment!(payment_id: 'PM1', amount_major: 10)

    assert_equal 10, order.reload.amount_paid
    assert_equal %w[PM1], order.gocardless_payment_ids
    refute order.payment_completed?
  end

  test 'create_schedule_for_order! stores mandate and schedule ids' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(
      :organisation,
      account: account,
      gocardless_access_token: 'sandbox_token',
      gocardless_instalment_count: 3
    )
    event = FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, currency: 'GBP')
    order = event.orders.create!(
      account: account,
      currency: 'GBP',
      value: 30,
      amount_demanded: 30,
      amount_paid: 0,
      instalment_count: 3,
      gocardless_billing_request_id: 'BRQ789',
      payment_completed: false,
      original_description: 'Festival tickets'
    )

    billing_request = OpenStruct.new(
      links: OpenStruct.new(mandate_request_mandate: 'MD123'),
      mandate_request: { 'links' => { 'mandate' => 'MD123' } }
    )
    mandate = OpenStruct.new(next_possible_charge_date: '2026-08-14')
    schedule = OpenStruct.new(id: 'IS999')
    captured_params = nil

    client = Object.new
    billing_requests = Object.new
    mandates = Object.new
    instalment_schedules = Object.new

    billing_requests.define_singleton_method(:get) { |_id| billing_request }
    mandates.define_singleton_method(:get) { |_id| mandate }
    instalment_schedules.define_singleton_method(:create_with_schedule) do |options|
      captured_params = options[:params]
      schedule
    end
    client.define_singleton_method(:billing_requests) { billing_requests }
    client.define_singleton_method(:mandates) { mandates }
    client.define_singleton_method(:instalment_schedules) { instalment_schedules }

    GoCardlessPro::Client.stub :new, client do
      EventPaymentMethod::GoCardlessInstalments.create_schedule_for_order!(order)
    end

    order.reload
    assert_equal 'MD123', order.gocardless_mandate_id
    assert_equal 'IS999', order.gocardless_instalment_schedule_id
    assert_equal 'GBP', captured_params[:currency]
    assert_equal 3000, captured_params[:total_amount]
    assert_equal [1000, 1000, 1000], captured_params[:instalments][:amounts]
    assert_equal 'MD123', captured_params[:links][:mandate]
  end
end
