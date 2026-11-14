require_relative '../test_config'

# Sharing an event's ticket revenue with an account's own Stripe account (the event's revenue sharer): once an order is
# paid, the charge the transfer made on the sharer's account is labelled with the buyer and the order
# (Order#update_destination_payment)
class PaymentsRevenueSharingTest < ActiveSupport::TestCase
  def create_revenue_sharing_event
    create_organisation(stripe_sk: 'sk_organisation')
    create_event(prices: [10])
    @sharer = FactoryBot.create(:account)
    @sharer.organisationships.create!(organisation: @organisation,
                                      stripe_connect_json: { 'stripe_user_id' => 'acct_sharer', 'access_token' => 'sk_sharer' }.to_json)
    @event.set(revenue_sharer_id: @sharer.id)
  end

  def create_unpaid_order(**attrs)
    @event.orders.create!(account: FactoryBot.create(:account), currency: @event.currency, value: 10, payment_intent: "pi_#{SecureRandom.hex(8)}",
                          application_fee_amount: 2, payment_completed: false, **attrs)
  end

  # Stubs the Stripe calls update_destination_payment makes, recording each with the key it used, and what's reported.
  # transfer is what retrieving the transfer answers, or an error it raises
  def with_stubbed_destination_payment(transfer: api_object(destination_payment: 'py_test'))
    calls = []
    reported = []
    Stripe::PaymentIntent.stub :retrieve, proc { |id, opts|
      calls << [:retrieve_payment_intent, id, opts[:api_key]]
      api_object(charges: [api_object(transfer: 'tr_test')])
    } do
      Stripe::Transfer.stub :retrieve, proc { |id, opts|
        calls << [:retrieve_transfer, id, opts[:api_key]]
        raise transfer if transfer.is_a?(Exception)

        transfer
      } do
        Stripe::Charge.stub :retrieve, proc { |id, opts|
          calls << [:retrieve_charge, id, opts[:api_key]]
          api_object(id: id)
        } do
          Stripe::Charge.stub :update, proc { |id, params, opts| calls << [:update_charge, id, params, opts[:api_key]] } do
            ErrorReporting.stub(:capture_exception, ->(error, **) { reported << error }) { yield calls, reported }
          end
        end
      end
    end
  end

  test "completing an order labels the charge the transfer made on the revenue sharer's account with the buyer and the order" do
    create_revenue_sharing_event
    order = create_unpaid_order

    with_stubbed_destination_payment do |calls, reported|
      order.complete_or_restore
      assert_empty reported

      assert_equal [
        [:retrieve_payment_intent, order.payment_intent, 'sk_organisation'],
        [:retrieve_transfer, 'tr_test', 'sk_organisation'],
        [:retrieve_charge, 'py_test', 'sk_sharer'],
        [:update_charge, 'py_test', { description: "#{order.account.name}: #{order.description}", metadata: order.metadata }, 'sk_sharer']
      ], calls
    end
    assert Order.find(order.id).payment_completed
  end

  test "orders with no application fee, or whose fee is a donation to Dandelion, leave Stripe's charges as they are" do
    create_revenue_sharing_event
    orders = [create_unpaid_order(application_fee_amount: nil), create_unpaid_order(application_fee_paid_to_dandelion: true)]

    with_stubbed_destination_payment do |calls, reported|
      orders.each(&:complete_or_restore)
      assert_empty calls
      assert_empty reported
    end
    assert(orders.all? { |order| Order.find(order.id).payment_completed })
  end

  test "an order whose transfer Stripe no longer has completes anyway, and isn't reported" do
    create_revenue_sharing_event
    order = create_unpaid_order

    with_stubbed_destination_payment(transfer: Stripe::InvalidRequestError.new('No such transfer: tr_test', 'id')) do |calls, reported|
      order.complete_or_restore
      assert_equal %i[retrieve_payment_intent retrieve_transfer], calls.map(&:first)
      assert_empty reported
    end
    assert Order.find(order.id).payment_completed
  end
end
