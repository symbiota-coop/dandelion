require_relative '../test_config'

# The nightly reconciliation of monthly donors with Dandelion's Stripe subscriptions
# (Account.reconcile_stripe_subscriptions, run by the daily errands): an account keeps its subscription id only while
# Stripe has that subscription in a status Dandelion keeps, and takes the newest kept subscription of a customer with
# its email
class PaymentsStripeSubscriptionsTest < ActiveSupport::TestCase
  # A subscription as Stripe's list gives it, with its customer expanded unless customer is a string
  def stripe_subscription(id, email: nil, status: 'active', created: Time.utc(2026, 10, 1), customer: { id: 'cus_1', email: email })
    Stripe::Subscription.construct_from(id: id, object: 'subscription', status: status, created: created.to_i, customer: customer)
  end

  # Runs Account.reconcile_stripe_subscriptions with Stripe's subscription list yielding these subscriptions page by
  # page through auto_paging_each (data holds only the first page); returns the [params, opts] the list was called with
  def reconcile(*pages)
    calls = []
    list = Struct.new(:pages) do
      def data = pages.first

      def auto_paging_each(&) = pages.flatten.each(&)
    end
    Stripe::Subscription.stub(:list, lambda { |params, opts|
      calls << [params, opts]
      list.new(pages)
    }) do
      Account.reconcile_stripe_subscriptions
    end
    calls
  end

  test "asks Stripe for all of Dandelion's subscriptions in every status, with their customers" do
    calls = reconcile([])
    assert_equal [[{ status: 'all', limit: 100, expand: ['data.customer'] }, StripeOpts.call]], calls
  end

  test "an account whose subscription isn't kept, or that Stripe no longer has, loses its id" do
    cancelled = FactoryBot.create(:account, email: 'cancelled@example.com', stripe_subscription_id: 'sub_cancelled')
    expired = FactoryBot.create(:account, email: 'expired@example.com', stripe_subscription_id: 'sub_expired')
    gone = FactoryBot.create(:account, email: 'gone@example.com', stripe_subscription_id: 'sub_gone')

    reconcile([stripe_subscription('sub_cancelled', email: 'cancelled@example.com', status: 'canceled'),
               stripe_subscription('sub_expired', email: 'expired@example.com', status: 'incomplete_expired')])

    assert_nil cancelled.reload.stripe_subscription_id
    assert_nil expired.reload.stripe_subscription_id
    assert_nil gone.reload.stripe_subscription_id
  end

  test 'an account whose subscription is active, trialing, past due or unpaid keeps it, on any page of the list' do
    accounts = %w[active trialing past_due unpaid].map do |status|
      FactoryBot.create(:account, email: "#{status}@example.com", stripe_subscription_id: "sub_#{status}")
    end

    reconcile([stripe_subscription('sub_active', email: 'active@example.com'),
               stripe_subscription('sub_trialing', email: 'trialing@example.com', status: 'trialing')],
              [stripe_subscription('sub_past_due', email: 'past_due@example.com', status: 'past_due'),
               stripe_subscription('sub_unpaid', email: 'unpaid@example.com', status: 'unpaid')])

    assert_equal(%w[sub_active sub_trialing sub_past_due sub_unpaid], accounts.map { |account| account.reload.stripe_subscription_id })
  end

  test "an account without a subscription id gets its customer's kept subscription, but not a cancelled one" do
    donor = FactoryBot.create(:account, email: 'donor@example.com')
    former_donor = FactoryBot.create(:account, email: 'former@example.com')

    reconcile([stripe_subscription('sub_donor', email: 'donor@example.com'),
               stripe_subscription('sub_former', email: 'former@example.com', status: 'canceled')])

    assert_equal 'sub_donor', donor.reload.stripe_subscription_id
    assert_nil former_donor.reload.stripe_subscription_id
  end

  test 'of two kept subscriptions for one email, the account takes the newer, whichever comes first' do
    donor = FactoryBot.create(:account, email: 'donor@example.com', stripe_subscription_id: 'sub_old')
    other_donor = FactoryBot.create(:account, email: 'other@example.com')

    reconcile([stripe_subscription('sub_old', email: 'donor@example.com', created: Time.utc(2026, 1, 1)),
               stripe_subscription('sub_new', email: 'donor@example.com', created: Time.utc(2026, 6, 1)),
               stripe_subscription('sub_other_new', email: 'other@example.com', created: Time.utc(2026, 6, 1)),
               stripe_subscription('sub_other_old', email: 'other@example.com', created: Time.utc(2026, 1, 1))])

    assert_equal 'sub_new', donor.reload.stripe_subscription_id
    assert_equal 'sub_other_new', other_donor.reload.stripe_subscription_id
  end

  test "a customer's email matches its account's whatever its case or surrounding spaces" do
    donor = FactoryBot.create(:account, email: 'donor@example.com')
    other_donor = FactoryBot.create(:account, email: 'other@example.com')

    reconcile([stripe_subscription('sub_donor', email: 'Donor@Example.COM'),
               stripe_subscription('sub_other', email: ' other@example.com ')])

    assert_equal 'sub_donor', donor.reload.stripe_subscription_id
    assert_equal 'sub_other', other_donor.reload.stripe_subscription_id
  end

  test 'an account already on its newest kept subscription is left alone' do
    FactoryBot.create(:account, email: 'donor@example.com', stripe_subscription_id: 'sub_donor')

    commands = mongo_commands_during { reconcile([stripe_subscription('sub_donor', email: 'donor@example.com')]) }

    assert_empty(commands.select { |command| command['update'] == 'accounts' })
  end

  test "a kept subscription whose customer has no email, or wasn't expanded, keeps its account's id but gives none" do
    donor = FactoryBot.create(:account, email: 'donor@example.com', stripe_subscription_id: 'sub_no_email')
    other_donor = FactoryBot.create(:account, email: 'other@example.com', stripe_subscription_id: 'sub_unexpanded')
    newcomer = FactoryBot.create(:account, email: 'newcomer@example.com')

    reconcile([stripe_subscription('sub_no_email', email: nil),
               stripe_subscription('sub_unexpanded', customer: 'cus_unexpanded'),
               stripe_subscription('sub_newcomer', customer: { id: 'cus_newcomer' })])

    assert_equal 'sub_no_email', donor.reload.stripe_subscription_id
    assert_equal 'sub_unexpanded', other_donor.reload.stripe_subscription_id
    assert_nil newcomer.reload.stripe_subscription_id
  end

  test 'a kept subscription with no account for its email creates or changes none' do
    donor = FactoryBot.create(:account, email: 'donor@example.com', stripe_subscription_id: 'sub_donor')

    assert_no_difference -> { Account.count } do
      reconcile([stripe_subscription('sub_donor', email: 'donor@example.com'),
                 stripe_subscription('sub_stranger', email: 'stranger@example.com')])
    end

    assert_equal 'sub_donor', donor.reload.stripe_subscription_id
    assert_not Account.and(stripe_subscription_id: 'sub_stranger').exists?
  end
end
