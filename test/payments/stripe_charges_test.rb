require_relative '../test_config'

# The charges and balance transactions synced each day from an organisation's own Stripe account (StripeCharge.transfer,
# StripeTransaction.transfer, then each charge's balance and fees from its transactions), and what an event's money
# reports read from them: its revenue, fees, donations and ticket revenue as Stripe has them
class PaymentsStripeChargesTest < ActiveSupport::TestCase
  include Capybara::DSL

  # A list of Stripe charges over pages: auto_paging_each yields them all, though data holds only the first page
  def stripe_pages(*pages)
    Struct.new(:pages) do
      def data = pages.first

      def auto_paging_each(&) = pages.flatten.each(&)
    end.new(pages)
  end

  # A charge as Stripe's list gives it, in cents of a lowercase currency, with a Dandelion order's metadata
  def stripe_charge(id, amount: 3000, currency: 'gbp', created: Time.utc(2026, 11, 5, 12), metadata: {}, **attributes)
    Stripe::Charge.construct_from(
      id: id, object: 'charge', amount: amount, currency: currency, created: created.to_i, balance_transaction: "txn_#{id}",
      customer: 'cus_1', description: 'An event, 5th November: Standard £30x1', payment_intent: "pi_#{id}", application_fee: nil,
      application_fee_amount: nil, destination: nil, metadata: metadata, **attributes
    )
  end

  # Runs the block with Stripe's charge list answering these pages; yields the params and options it was called with
  def with_stripe_charges(*pages)
    calls = []
    Stripe::Charge.stub(:list, lambda { |params, opts|
      calls << [params, opts]
      stripe_pages(*pages)
    }) do
      capture_io { yield calls }
    end
  end

  TRANSACTION_HEADERS = %w[balance_transaction_id created_utc available_on_utc currency gross fee net reporting_category source_id description
                           customer_facing_amount customer_facing_currency automatic_payout_id automatic_payout_effective_at charge_id].freeze

  # Stripe's itemized balance change report, as the CSV its file downloads as
  def transactions_csv(rows)
    CSV.generate do |csv|
      csv << TRANSACTION_HEADERS
      rows.each { |row| csv << TRANSACTION_HEADERS.map { |header| row[header.to_sym] } }
    end
  end

  # Runs the block with Stripe's report run finishing on its second look, and its file downloading as this CSV; yields
  # what was asked of Stripe
  def with_stripe_transactions_report(csv)
    calls = { created: [], retrieved: [], downloads: [] }
    http = Object.new
    http.define_singleton_method(:request) do |request|
      calls[:downloads] << [request.path, request['authorization']]
      Struct.new(:body).new(csv)
    end
    Stripe::Reporting::ReportRun.stub(:create, lambda { |params, opts|
      calls[:created] << [params, opts]
      Struct.new(:id, :result).new('frr_1', nil)
    }) do
      Stripe::Reporting::ReportRun.stub(:retrieve, lambda { |id, _opts|
        calls[:retrieved] << id
        Struct.new(:id, :result).new(id, Struct.new(:url).new('https://files.stripe.com/v1/files/file_1/contents'))
      }) do
        StripeTransaction.stub(:sleep, nil) do
          Net::HTTP.stub(:start, lambda { |host, _port, use_ssl:, &block|
            calls[:downloads] << [host, use_ssl]
            block.call(http)
          }) do
            capture_io { yield calls }
          end
        end
      end
    end
  end

  def organisation_with_own_stripe
    create_event(prices: [30], currency: 'GBP')
    @organisation.set(stripe_sk: 'sk_live_own', stripe_client_id: 'ca_own')
  end

  # The organisation's charges as stored: a sync's create of a charge already stored fails, but leaves the unsaved copy
  # in the organisation's loaded stripe_charges
  def stored_charges
    StripeCharge.and(organisation_id: @organisation.id)
  end

  # Charges, with the balance and fees the daily task gives them from their transactions

  def charge(id, **attributes)
    @organisation.stripe_charges.create!(id: id, event: @event, amount: 3000, currency: 'gbp', created: Time.utc(2026, 11, 5, 12),
                                         balance_transaction: "txn_#{id}", de_donation_revenue: 0, **attributes)
  end

  def transaction(stripe_charge, gross:, fee: 0, currency: 'gbp', category: 'charge')
    @organisation.stripe_transactions.create!(id: "txn_#{SecureRandom.hex(4)}", stripe_charge: stripe_charge, gross: gross, fee: fee,
                                              net: gross - fee, currency: currency, reporting_category: category)
  end

  # Syncing charges

  test 'syncing stores the day’s charges from the organisation’s own Stripe account, linked to their order, event and account' do
    organisation_with_own_stripe
    buyer = FactoryBot.create(:account)
    order = @event.orders.create!(account: buyer, currency: 'GBP', value: 30, payment_completed: true)
    metadata = { de_event_id: @event.id.to_s, de_order_id: order.id.to_s, de_account_id: buyer.id.to_s, de_donation_revenue: '5,00',
                 de_ticket_revenue: '25.00', de_discounted_ticket_revenue: '22,50', de_percentage_discount: '10',
                 de_credit_applied: '0,50', de_fixed_discount_applied: '2' }
    charges = [stripe_charge('ch_1', application_fee: 'fee_1', application_fee_amount: 1000, destination: 'acct_sharer', metadata: metadata)]

    with_stripe_charges(charges) do |calls|
      StripeCharge.transfer(@organisation, from: Date.new(2026, 11, 5), to: Date.new(2026, 11, 6))
      params, opts = calls.sole
      assert_equal({ gte: Time.utc(2026, 11, 5).to_i, lt: Time.utc(2026, 11, 6).to_i }, params[:created])
      # The organisation's own secret key, not the platform's on its behalf
      assert_equal 'sk_live_own', opts[:api_key]
      assert_nil opts[:stripe_account]
    end

    stripe_charge = stored_charges.sole
    assert_equal ['ch_1', @event, order, buyer], [stripe_charge.id, stripe_charge.event, stripe_charge.order, stripe_charge.account]
    assert_equal [3000, 'gbp', 'fee_1', 1000, 'acct_sharer', 'txn_ch_1', 'cus_1', 'pi_ch_1'],
                 stripe_charge.attributes.values_at(*%w[amount currency application_fee application_fee_amount destination balance_transaction customer
                                                        payment_intent])
    assert_equal 'An event, 5th November: Standard £30x1', stripe_charge.description
    assert_equal Time.utc(2026, 11, 5, 12), stripe_charge.created
    # Amounts in metadata written with a decimal comma are read as decimals
    assert_equal [5.0, 25.0, 22.5, 10.0, 0.5, 2.0], stripe_charge.attributes.values_at(*%w[de_donation_revenue de_ticket_revenue de_discounted_ticket_revenue
                                                                                         de_percentage_discount de_credit_applied de_fixed_discount_applied])
    assert_nil stripe_charge.de_percentage_discount_monthly_donor
    # Until its transactions are synced, it has no balance or fees
    assert_equal [0.0, 0.0], [stripe_charge.balance_float, stripe_charge.fees_float]
    assert_equal '£30', stripe_charge.summary
  end

  test 'syncing takes every page of the charges Stripe lists' do
    organisation_with_own_stripe

    with_stripe_charges([stripe_charge('ch_1')], [stripe_charge('ch_2'), stripe_charge('ch_3')]) do
      StripeCharge.transfer(@organisation, from: Date.new(2026, 11, 5), to: Date.new(2026, 11, 6))
    end

    assert_equal %w[ch_1 ch_2 ch_3], stored_charges.pluck(:id).sort
  end

  test 'syncing a charge again keeps the one stored, with the balance its transactions gave it, rather than adding another' do
    organisation_with_own_stripe
    charges = [stripe_charge('ch_1', metadata: { de_event_id: @event.id.to_s })]
    with_stripe_charges(charges) { StripeCharge.transfer(@organisation, from: Date.new(2026, 11, 5), to: Date.new(2026, 11, 6)) }
    stored_charges.sole.set(balance_float: 30, fees_float: 1.2)

    with_stripe_charges(charges + [stripe_charge('ch_2')]) do
      StripeCharge.transfer(@organisation, from: Date.new(2026, 11, 5), to: Date.new(2026, 11, 7))
    end

    assert_equal %w[ch_1 ch_2], stored_charges.pluck(:id).sort
    kept = stored_charges.find('ch_1')
    assert_equal [30.0, 1.2], [kept.balance_float, kept.fees_float]
  end

  test 'a charge made outside Dandelion is stored for the organisation but on no event, and one whose order is gone keeps its event' do
    organisation_with_own_stripe
    charges = [
      stripe_charge('ch_dashboard', description: nil),
      stripe_charge('ch_gone', metadata: { de_event_id: @event.id.to_s, de_order_id: BSON::ObjectId.new.to_s })
    ]

    with_stripe_charges(charges) { StripeCharge.transfer(@organisation, from: Date.new(2026, 11, 5), to: Date.new(2026, 11, 6)) }

    dashboard = stored_charges.find('ch_dashboard')
    assert_equal [nil, nil, nil, nil], [dashboard.event, dashboard.order, dashboard.account, dashboard.description]
    gone = stored_charges.find('ch_gone')
    assert_equal @event, gone.event
    assert_nil gone.order
    assert_equal %w[ch_gone], @event.stripe_charges.pluck(:id)
  end

  test 'syncing asks Stripe nothing when the period is empty' do
    organisation_with_own_stripe

    with_stripe_charges([]) do |calls|
      StripeCharge.transfer(@organisation, from: Date.new(2026, 11, 6), to: Date.new(2026, 11, 6))
      assert_empty calls
    end
    assert_nil StripeTransaction.transfer(@organisation, from: Date.new(2026, 11, 6), to: Date.new(2026, 11, 5))
  end

  # Syncing balance transactions

  test 'syncing transactions waits for Stripe’s report, then stores each row against its charge, once' do
    organisation_with_own_stripe
    stripe_charge = charge('ch_1')
    csv = transactions_csv([
                             { balance_transaction_id: 'txn_1', created_utc: '2026-11-05 12:00:00', available_on_utc: '2026-11-12 00:00:00', currency: 'gbp',
                               gross: '30.00', fee: '1.20', net: '28.80', reporting_category: 'charge', source_id: 'ch_1', charge_id: 'ch_1',
                               customer_facing_amount: '30.00', customer_facing_currency: 'gbp' },
                             { balance_transaction_id: 'txn_2', created_utc: '2026-11-05 18:00:00', available_on_utc: '2026-11-05 18:00:00', currency: 'gbp',
                               gross: '-10.00', fee: '0.00', net: '-10.00', reporting_category: 'refund', source_id: 're_1', charge_id: 'ch_1',
                               automatic_payout_id: 'po_1', automatic_payout_effective_at: '2026-11-13 00:00:00' }
                           ])

    with_stripe_transactions_report(csv) do |calls|
      StripeTransaction.transfer(@organisation, from: Date.new(2026, 11, 5), to: Date.new(2026, 11, 6))
      StripeTransaction.transfer(@organisation, from: Date.new(2026, 11, 5), to: Date.new(2026, 11, 6))
      params, opts = calls[:created].first
      assert_equal 'balance_change_from_activity.itemized.1', params[:report_type]
      assert_equal({ interval_start: Time.utc(2026, 11, 5).to_i, interval_end: Time.utc(2026, 11, 6).to_i }, params[:parameters])
      assert_equal 'sk_live_own', opts[:api_key]
      assert_equal %w[frr_1 frr_1], calls[:retrieved]
      # Downloaded with the organisation's key
      assert_equal ['files.stripe.com', true], calls[:downloads][0]
      assert_equal ['/v1/files/file_1/contents', "Basic #{Base64.strict_encode64('sk_live_own:')}"], calls[:downloads][1]
    end

    assert_equal %w[txn_1 txn_2], stripe_charge.stripe_transactions.pluck(:id).sort
    sale, refund = %w[txn_1 txn_2].map { |id| StripeTransaction.find(id) }
    assert_equal [30.0, 1.2, 28.8, 'gbp', 'charge'], [sale.gross, sale.fee, sale.net, sale.currency, sale.reporting_category]
    assert_equal [Time.utc(2026, 11, 5, 12), Time.utc(2026, 11, 12)], [sale.created_utc, sale.available_on_utc]
    assert_nil sale.automatic_payout_effective_at
    assert_equal [-10.0, 're_1', 'po_1', Time.utc(2026, 11, 13)], [refund.gross, refund.source_id, refund.automatic_payout_id, refund.automatic_payout_effective_at]
  end

  # Balance and fees from transactions

  test 'a charge’s balance is what its transactions leave of it, less refunds and disputes, and its fees are theirs added up' do
    create_event(prices: [30], currency: 'GBP')
    paid = charge('ch_paid')
    transaction(paid, gross: 30, fee: 1.2)
    partly_refunded = charge('ch_partly_refunded')
    transaction(partly_refunded, gross: 30, fee: 1.2)
    transaction(partly_refunded, gross: -12.5, category: 'refund')
    refunded = charge('ch_refunded')
    transaction(refunded, gross: 30, fee: 1.2)
    transaction(refunded, gross: -30, category: 'refund')
    # A lost dispute takes the charge back and adds a dispute fee
    disputed = charge('ch_disputed')
    transaction(disputed, gross: 30, fee: 1.2)
    transaction(disputed, gross: -30, fee: 20, category: 'dispute')
    # More refunded than was charged leaves no balance, not less than none
    overrefunded = charge('ch_overrefunded')
    transaction(overrefunded, gross: 30, fee: 1.2)
    transaction(overrefunded, gross: -35, category: 'refund')
    unsettled = charge('ch_unsettled')

    balances_and_fees = [paid, partly_refunded, refunded, disputed, overrefunded, unsettled].map do |stripe_charge|
      [stripe_charge.balance_from_transactions.format, stripe_charge.fees_from_transactions.format]
    end
    assert_equal [%w[£30.00 £1.20], %w[£17.50 £1.20], %w[£0.00 £1.20], %w[£0.00 £21.20], %w[£0.00 £1.20], %w[£0.00 £0.00]], balances_and_fees
  end

  test 'transactions settled in another currency give the charge’s balance and fees in the charge’s currency' do
    create_event(prices: [30], currency: 'EUR')
    stripe_charge = charge('ch_1', currency: 'eur')
    transaction(stripe_charge, gross: 24, fee: 0.96, currency: 'gbp')

    Money.default_bank.stub(:get_rate, ->(from, to, *) { { %w[GBP EUR] => 1.25 }.fetch([from.to_s, to.to_s]) }) do
      assert_equal Money.new(3000, 'EUR'), stripe_charge.balance_from_transactions
      assert_equal Money.new(120, 'EUR'), stripe_charge.fees_from_transactions
      # As the daily task stores them
      stripe_charge.set(balance_float: stripe_charge.balance_from_transactions, fees_float: stripe_charge.fees_from_transactions)
    end

    stripe_charge.reload
    assert_equal [30.0, 1.2], [stripe_charge.balance_float, stripe_charge.fees_float]
    assert_equal [Money.new(3000, 'EUR'), Money.new(120, 'EUR')], [stripe_charge.balance, stripe_charge.fees]
  end

  # What reports read

  test 'a charge with no application fee is all the organisation’s, its donations coming out of its balance first' do
    create_event(prices: [30], currency: 'GBP')
    paid = charge('ch_paid', balance_float: 30, de_donation_revenue: 5)
    partly_refunded = charge('ch_partly_refunded', balance_float: 20, de_donation_revenue: 5)

    # Ticket revenue, to the organisation, to a revenue sharer, donations
    assert_equal %w[£25.00 £25.00 £0.00 £5.00], [paid.ticket_revenue, paid.ticket_revenue_to_organisation, paid.ticket_revenue_to_revenue_sharer, paid.donations].map(&:format)
    assert_equal %w[£15.00 £15.00 £0.00 £5.00],
                 [partly_refunded.ticket_revenue, partly_refunded.ticket_revenue_to_organisation, partly_refunded.ticket_revenue_to_revenue_sharer,
                  partly_refunded.donations].map(&:format)
  end

  test 'a charge with no application fee refunded below its donation, or in full, has no ticket revenue, rather than less than none' do
    create_event(prices: [30], currency: 'GBP')
    mostly_refunded = charge('ch_mostly_refunded', balance_float: 3, de_donation_revenue: 5)
    refunded = charge('ch_refunded', balance_float: 0, de_donation_revenue: 5)

    # Ticket revenue, to the organisation, donations: what's left of the balance is the donation's
    figures = [mostly_refunded, refunded].map do |stripe_charge|
      [stripe_charge.ticket_revenue, stripe_charge.ticket_revenue_to_organisation, stripe_charge.donations].map(&:format)
    end
    assert_equal [%w[£0.00 £0.00 £3.00], %w[£0.00 £0.00 £0.00]], figures
    event = Event.find(@event.id)
    assert_equal %w[£3.00 £0.00 £3.00], [event.stripe_revenue, event.stripe_ticket_revenue, event.stripe_donations].map(&:format)
  end

  test 'a charge shared with a revenue sharer splits its ticket revenue by the application fee, in proportion to what is left of it' do
    create_event(prices: [30], currency: 'GBP')
    # £30 paid, £20 of it to the revenue sharer, so the organisation's balance is the £10 application fee: £5 of tickets
    # and a £5 donation
    attributes = { amount: 3000, application_fee_amount: 1000, de_discounted_ticket_revenue: 25, de_donation_revenue: 5 }
    paid = charge('ch_paid', balance_float: 10, **attributes)
    half_refunded = charge('ch_half_refunded', balance_float: 5, **attributes)
    refunded = charge('ch_refunded', balance_float: 0, **attributes)
    # An application fee of nothing gives the organisation no balance, and the revenue sharer all of it
    all_to_sharer = charge('ch_all_to_sharer', balance_float: 0, amount: 3000, application_fee_amount: 0, de_discounted_ticket_revenue: 30)

    figures = [paid, half_refunded, refunded, all_to_sharer].map do |stripe_charge|
      [stripe_charge.ticket_revenue, stripe_charge.ticket_revenue_to_organisation, stripe_charge.ticket_revenue_to_revenue_sharer, stripe_charge.donations].map(&:format)
    end
    assert_equal [
      %w[£25.00 £5.00 £20.00 £5.00],
      %w[£12.50 £2.50 £10.00 £2.50],
      %w[£0.00 £0.00 £0.00 £0.00],
      %w[£30.00 £0.00 £30.00 £0.00]
    ], figures
  end

  test 'an event’s Stripe totals add up its charges, and its charges with a balance are split by whether their order was transferred' do
    create_event(prices: [30], currency: 'GBP')
    buyer = FactoryBot.create(:account)
    transferred_order = @event.orders.create!(account: buyer, currency: 'GBP', value: 20, payment_completed: true)
    transferred_order.set(transferred: true)
    paid = charge('ch_paid', balance_float: 30, fees_float: 1.2, de_donation_revenue: 5)
    charge('ch_refunded', balance_float: 0, fees_float: 0.8)
    transferred = charge('ch_transferred', order: transferred_order, balance_float: 20, fees_float: 0.6)
    charge('ch_other_event', event: FactoryBot.create(:event, organisation: @organisation), balance_float: 100, fees_float: 3)

    event = Event.find(@event.id)
    assert_equal %w[£50.00 £2.60 £5.00 £45.00 £45.00 £0.00],
                 [event.stripe_revenue, event.stripe_fees, event.stripe_donations, event.stripe_ticket_revenue, event.stripe_ticket_revenue_to_organisation,
                  event.stripe_ticket_revenue_to_revenue_sharer].map(&:format)
    assert_equal [[paid], [transferred]], event.stripe_charges_by_transfer
  end

  test 'an event admin sees a charge with no description among the event’s Stripe charges' do
    create_event(prices: [30], currency: 'GBP')
    charge('ch_described', description: "#{@event.name}: 1 ticket", balance_float: 30)
    # Charges made or edited in Stripe's dashboard can have none
    charge('ch_undescribed', description: nil, balance_float: 30, created: Time.utc(2026, 11, 4))

    sign_in(@account)
    visit "/e/#{@event.slug}/stripe_charges"
    assert page.has_css?('#stripe-charges tbody tr', count: 2)
    # Charge ID, description
    rows = all('#stripe-charges tbody tr').map { |row| row.all('td').map { |cell| cell.text.squish }.values_at(1, 2) }
    assert_equal [['ch_described', '1 ticket'], ['ch_undescribed', '']], rows
  end
end
