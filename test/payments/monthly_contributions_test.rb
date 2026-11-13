require_relative '../test_config'

# What Dandelion took each month, from Stripe charges and Connect application fees less Stripe's fees, in pounds
# (MonthlyContributionsCalculator), cached in the monthly_contributions fragment that the stats page and the progress
# bar read
class PaymentsMonthlyContributionsTest < ActiveSupport::TestCase
  RATES = { %w[USD GBP] => 0.75, %w[EUR GBP] => 0.8, %w[GBP EUR] => 1.25 }.freeze

  # A Stripe list whose auto_paging_each yields these items
  def stripe_list(items)
    Struct.new(:data) do
      def auto_paging_each(&)
        data.each(&)
      end
    end.new(items)
  end

  def charge_object(amount:, currency: 'gbp', status: 'succeeded', refunded: false, amount_refunded: 0, payment_intent: 'pi_1', fee: nil,
             fee_currency: 'gbp')
    balance_transaction = { 'fee' => fee, 'currency' => fee_currency } if fee
    api_object(amount: amount, currency: currency, status: status, refunded: refunded, amount_refunded: amount_refunded,
               payment_intent: payment_intent, balance_transaction: balance_transaction)
  end

  def application_fee(amount:, currency: 'gbp', refunded: false, amount_refunded: 0, fee: nil, fee_currency: 'gbp')
    balance_transaction = { 'fee' => fee, 'currency' => fee_currency } if fee
    api_object(amount: amount, currency: currency, refunded: refunded, amount_refunded: amount_refunded,
               balance_transaction: balance_transaction)
  end

  # Runs the block with Stripe's lists answering these charges and application fees, and fixed exchange rates; yields
  # the params each list was called with
  def with_stripe(charges: [], fees: [])
    calls = { charges: [], fees: [] }
    Money.default_bank.stub(:get_rate, ->(from, to, *) { RATES.fetch([from.to_s, to.to_s]) }) do
      Stripe::Charge.stub(:list, lambda { |params, _opts|
        calls[:charges] << params
        stripe_list(charges)
      }) do
        Stripe::ApplicationFee.stub(:list, lambda { |params, _opts|
          calls[:fees] << params
          stripe_list(fees)
        }) do
          yield calls
        end
      end
    end
  end

  def contributions_fragment(data)
    Fragment.create!(key: 'monthly_contributions', value: data.to_json, expires: 2.days.from_now)
  end

  test "a month's contributions are its succeeded charges and its application fees, less Stripe's fees, in whole pounds" do
    charges = [
      charge_object(amount: 10_000, fee: 170),
      charge_object(amount: 2000, currency: 'usd', fee: 100),
      charge_object(amount: 500),
      charge_object(amount: 5000, status: 'failed', fee: 175),
      charge_object(amount: 3000, refunded: true, fee: 120),
      charge_object(amount: 7000, payment_intent: 'pi_ignored', fee: 150)
    ]
    fees = [
      application_fee(amount: 1000, fee: 50),
      application_fee(amount: 400, currency: 'eur', fee: 20, fee_currency: nil),
      application_fee(amount: 900, refunded: true, fee: 30)
    ]
    with_env('STRIPE_PAYMENT_INTENTS_TO_IGNORE' => 'pi_other,pi_ignored') do
      with_stripe(charges: charges, fees: fees) do
        # Charges: £100 + $20 (£15) + £5 = £120, less £1.70 + £1 in fees = £117.30. Application fees: £10 + €4 (£3.20)
        # = £13.20, less 50p + 20 cents (15p, a fee with no currency being in dollars) = £12.55. £129.85 in all
        assert_equal ['February 2026', 129, { 'direct_stripe_charges' => 117, 'stripe_connect_application_fees' => 12 }],
                     MonthlyContributionsCalculator.calculate_month_data(Date.new(2026, 2, 1))
      end
    end
  end

  test 'asks Stripe for the charges and application fees created in the month, with their balance transactions' do
    with_stripe do |calls|
      MonthlyContributionsCalculator.calculate_month_data(Date.new(2026, 2, 1))
      expected = {
        created: { gte: Time.utc(2026, 2, 1).to_i, lt: Time.utc(2026, 3, 1).to_i },
        limit: 100,
        expand: ['data.balance_transaction']
      }
      assert_equal [expected], calls[:charges]
      assert_equal [expected], calls[:fees]
    end
  end

  test 'months run midnight to midnight UTC, whatever the time zone' do
    with_env('TZ' => 'Europe/Stockholm') do
      with_stripe do |calls|
        MonthlyContributionsCalculator.calculate_month_data(Date.new(2026, 7, 1))
        # 1 July and 1 August 2026 at 00:00 UTC: 20,635 and 20,666 days after 1 January 1970, times 86,400 seconds
        # (Stockholm's midnights, in summer time, would be two hours earlier)
        assert_equal({ gte: 1_782_864_000, lt: 1_785_542_400 }, calls[:charges].first[:created])
        assert_equal({ gte: 1_782_864_000, lt: 1_785_542_400 }, calls[:fees].first[:created])
      end
    end
  end

  test 'a partially refunded charge or application fee counts what was kept, less the whole of Stripe\'s fee' do
    charges = [charge_object(amount: 10_000, amount_refunded: 4000, fee: 170)]
    fees = [application_fee(amount: 1000, amount_refunded: 250, fee: 10)]
    with_stripe(charges: charges, fees: fees) do
      # Charges: £100 less £40 refunded = £60, less the £1.70 fee Stripe keeps = £58.30. Application fees: £10 less
      # £2.50 refunded = £7.50, less 10p = £7.40
      assert_equal ['February 2026', 65, { 'direct_stripe_charges' => 58, 'stripe_connect_application_fees' => 7 }],
                   MonthlyContributionsCalculator.calculate_month_data(Date.new(2026, 2, 1))
    end
  end

  test 'the total is the sum of its whole-pound parts' do
    with_stripe(charges: [charge_object(amount: 1060)], fees: [application_fee(amount: 1060)]) do
      # £10.60 and £10.60 are £10 and £10, so £20 in all (not £21.20 cut to £21)
      assert_equal ['February 2026', 20, { 'direct_stripe_charges' => 10, 'stripe_connect_application_fees' => 10 }],
                   MonthlyContributionsCalculator.calculate_month_data(Date.new(2026, 2, 1))
    end
  end

  test 'a month with no charges or application fees is zero' do
    with_stripe do
      assert_equal ['March 2026', 0, { 'direct_stripe_charges' => 0, 'stripe_connect_application_fees' => 0 }],
                   MonthlyContributionsCalculator.calculate_month_data(Date.new(2026, 3, 1))
    end
  end

  test 'the months are the last 24 and this one, oldest first' do
    travel_to Time.local(2026, 11, 12, 12) do
      months = MonthlyContributionsCalculator.generate_month_range
      assert_equal 25, months.length
      assert_equal Date.new(2024, 11, 1), months.first
      assert_equal Date.new(2026, 11, 1), months.last
      assert_equal (0..24).map { |i| Date.new(2024, 11, 1) + i.months }, months
    end
  end

  test 'calculate caches every month in the fragment for two days' do
    travel_to Time.local(2026, 11, 12, 12) do
      with_stripe(charges: [charge_object(amount: 1000)]) do
        MonthlyContributionsCalculator.calculate
      end
      fragment = Fragment.find_by(key: 'monthly_contributions')
      data = JSON.parse(fragment.value)
      assert_equal 25, data.length
      assert_equal ['November 2024', 10, { 'direct_stripe_charges' => 10, 'stripe_connect_application_fees' => 0 }], data.first
      assert_equal 'November 2026', data.last[0]
      assert_equal 2.days.from_now.to_i, fragment.expires.to_i
    end
  end

  test "updating the current month replaces its entry and keeps the other months'" do
    travel_to Time.local(2026, 11, 12, 12) do
      fragment = contributions_fragment([['October 2026', 50, {}], ['November 2026', 1, {}]])
      with_stripe(charges: [charge_object(amount: 4200)]) do
        MonthlyContributionsCalculator.update_current_month
      end
      assert_equal [
        ['October 2026', 50, {}],
        ['November 2026', 42, { 'direct_stripe_charges' => 42, 'stripe_connect_application_fees' => 0 }]
      ], JSON.parse(fragment.reload.value)
    end
  end

  test 'updating the current month adds it when the fragment has no entry for it yet' do
    travel_to Time.local(2026, 11, 12, 12) do
      fragment = contributions_fragment([['October 2026', 50, {}]])
      with_stripe { MonthlyContributionsCalculator.update_current_month }
      assert_equal [
        ['October 2026', 50, {}],
        ['November 2026', 0, { 'direct_stripe_charges' => 0, 'stripe_connect_application_fees' => 0 }]
      ], JSON.parse(fragment.reload.value)
    end
  end

  test 'updating the current month does nothing until calculate has made the fragment' do
    Stripe::Charge.stub(:list, ->(*) { flunk 'Stripe was asked' }) do
      assert_nil MonthlyContributionsCalculator.update_current_month
    end
    assert_nil Fragment.find_by(key: 'monthly_contributions')
  end

  test "contribution_data gives this month's contributions and projects them over the whole month" do
    travel_to Time.local(2026, 11, 12, 12) do
      contributions_fragment([['October 2026', 900, {}], ['November 2026', 300, {}]])
      # £300 in 12 days of November's 30
      assert_equal({ current: Money.new(30_000, 'GBP'), projected: 750, currency: 'GBP' },
                   MonthlyContributionsCalculator.contribution_data('GBP'))
    end
  end

  test 'contribution_data exchanges into the currency asked for, and rounds the projection' do
    travel_to Time.local(2026, 11, 12, 12) do
      contributions_fragment([['November 2026', 300, {}]])
      with_stripe do
        # €375, and 375 / 12 * 30 = 937.5
        assert_equal({ current: Money.new(37_500, 'EUR'), projected: 938, currency: 'EUR' },
                     MonthlyContributionsCalculator.contribution_data('EUR'))
      end
    end
  end

  test 'contribution_data defaults to the default currency, or pounds when there is none' do
    travel_to Time.local(2026, 11, 12, 12) do
      contributions_fragment([['November 2026', 300, {}]])
      with_stripe do
        with_env('DEFAULT_CURRENCY' => 'EUR') do
          assert_equal 'EUR', MonthlyContributionsCalculator.contribution_data[:currency]
        end
        with_env('DEFAULT_CURRENCY' => nil) do
          assert_equal 'GBP', MonthlyContributionsCalculator.contribution_data[:currency]
        end
      end
    end
  end

  test 'contribution_data is nil without a fragment, without this month, or with nothing this month' do
    travel_to Time.local(2026, 11, 12, 12) do
      assert_nil MonthlyContributionsCalculator.contribution_data('GBP')

      fragment = contributions_fragment([['October 2026', 900, {}]])
      assert_nil MonthlyContributionsCalculator.contribution_data('GBP')

      fragment.update_attributes!(value: [['November 2026', 0, {}]].to_json)
      assert_nil MonthlyContributionsCalculator.contribution_data('GBP')
    end
  end
end
