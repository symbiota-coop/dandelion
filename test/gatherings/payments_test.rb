require_relative '../test_config'

# Members paying into a gathering: starting a payment by card (Stripe Checkout, on the gathering's own keys) or EVM,
# the gathering's Stripe webhook completing it and crediting the membership once, and checking on a payment
class GatheringPaymentsTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  ENDPOINT_SECRET = 'whsec_gathering_test'.freeze
  EVM_ADDRESS = '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed'.freeze

  def create_paying_gathering(**attrs)
    create_gathering(stripe_sk: 'sk_test_gathering', stripe_pk: 'pk_test_gathering', stripe_endpoint_secret: ENDPOINT_SECRET, **attrs)
  end

  def membership_of(account, gathering = @gathering)
    gathering.memberships.find_by(account: account)
  end

  # Posts to the pay route as the page's jQuery does
  def post_pay(**params)
    header 'Accept', 'application/json'
    header 'X-Requested-With', 'XMLHttpRequest'
    post gathering_path("/pay"), params
  end

  # Starts a card payment for amount, with Stripe's session creation stubbed, returning what Stripe was sent
  def pay_by_card(amount, **params)
    sent = {}
    session = api_object(id: "cs_#{SecureRandom.hex(4)}", payment_intent: "pi_#{SecureRandom.hex(4)}")
    Stripe::Checkout::Session.stub(:create, proc { |hash, opts|
      sent[:hash] = hash
      sent[:opts] = opts
      session
    }) do
      post_pay(payment_method: 'stripe', amount: amount, **params)
    end
    sent
  end

  def refusing_stripe(&)
    Stripe::Checkout::Session.stub(:create, proc { flunk 'no Stripe session should be made' }, &)
  end

  # A payment made by membership through Stripe and waiting for its webhook
  def create_unpaid_payment(membership, amount: 10)
    membership.payments.create!(amount: amount, currency: membership.gathering.currency, session_id: "cs_#{SecureRandom.hex(4)}")
  end

  def session_payload(session_id, type: 'checkout.session.completed', payment_status: 'paid')
    { id: "evt_#{SecureRandom.hex(4)}", object: 'event', type: type, data: { object: { id: session_id, object: 'checkout.session', payment_status: payment_status } } }.to_json
  end

  # Posts payload to the gathering's webhook as Stripe would, signed with secret
  def deliver_webhook(payload, gathering: @gathering, secret: ENDPOINT_SECRET)
    timestamp = Time.now
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret)
    header 'Stripe-Signature', Stripe::Webhook::Signature.generate_header(timestamp, signature)
    header 'Content-Type', 'application/json'
    post "/g/#{gathering.slug}/stripe_webhook", payload
  end

  def assert_uncredited(payment)
    refute payment.reload.payment_completed?
    assert_equal 0, payment.membership.reload.paid
    assert_equal 0, payment.gathering.reload.balance.to_i
  end

  # Paying

  test 'a member starts a card payment: an unpaid payment and a Stripe Checkout session on the gathering\'s own key' do
    create_paying_gathering
    member = create_member
    sign_in_with_rack(member)

    sent = pay_by_card('25', currency: 'USD')

    assert_equal 200, last_response.status, last_response.body
    payment = membership_of(member).payments.first
    assert_equal({ 'session_id' => payment.session_id }, JSON.parse(last_response.body))
    assert_equal 25, payment.amount
    assert_equal 'GBP', payment.currency # the gathering's, whatever is posted
    refute payment.payment_completed?
    assert_equal member.id, payment.account_id
    assert_equal @gathering.id, payment.gathering_id
    assert_equal @gathering.name, payment.gathering_name
    assert payment.payment_intent

    line_item = sent[:hash][:line_items].first
    assert_equal 2500, line_item[:amount]
    assert_equal 'GBP', line_item[:currency]
    assert_equal member.email, sent[:hash][:customer_email]
    assert_equal @gathering.id, sent[:hash][:metadata][:de_gathering_id]
    assert_equal member.id, sent[:hash][:metadata][:de_account_id]
    assert_equal 'sk_test_gathering', sent[:opts][:api_key]
    assert_nil sent[:opts][:stripe_account]

    # Nothing is credited until Stripe says it's paid
    assert_equal 0, membership_of(member).paid
  end

  test 'a member not yet confirmed, as the gathering demands a payment, can pay, and is confirmed once it\'s paid' do
    create_paying_gathering(demand_payment: true)
    member = create_member
    refute membership_of(member).confirmed?
    sign_in_with_rack(member)

    pay_by_card('10')
    assert_equal 200, last_response.status, last_response.body
    payment = membership_of(member).payments.first

    deliver_webhook(session_payload(payment.session_id))

    assert membership_of(member).confirmed?
  end

  test 'someone signed out, not a member, or a member of another gathering cannot start a payment' do
    create_paying_gathering
    other_gathering = FactoryBot.create(:gathering, account: FactoryBot.create(:account), stripe_sk: 'sk_test_other')
    other_member = FactoryBot.create(:account).tap { |account| other_gathering.memberships.create!(account: account) }

    refusing_stripe do
      post_pay(payment_method: 'stripe', amount: '10')
      assert_equal 403, last_response.status

      [FactoryBot.create(:account), other_member].each do |account|
        sign_in_with_rack(account)
        post_pay(payment_method: 'stripe', amount: '10')
        assert_equal 403, last_response.status
      end
    end
    assert_equal 0, Payment.count
  end

  test 'a payment method that is unknown, or that the gathering does not take, is refused' do
    create_paying_gathering
    sign_in_with_rack(create_member)

    refusing_stripe do
      post_pay(payment_method: 'bogus', amount: '10')
      assert_equal 400, last_response.status

      # EVM needs an address and a token currency
      post_pay(payment_method: 'evm', amount: '10')
      assert_equal 400, last_response.status

      # Card needs the gathering's secret key
      @gathering.set(stripe_sk: nil)
      post_pay(payment_method: 'stripe', amount: '10')
      assert_equal 400, last_response.status
    end
    assert_equal 0, Payment.count
  end

  # The webhook

  test 'a paid session completes its payment and credits the membership once, however often it is delivered' do
    create_paying_gathering
    member = create_member
    payment = create_unpaid_payment(membership_of(member), amount: 30)
    payload = session_payload(payment.session_id)

    deliver_webhook(payload)

    assert_equal 200, last_response.status
    assert payment.reload.payment_completed?
    assert_equal 30, membership_of(member).paid
    assert_equal 30, @gathering.reload.balance
    assert_equal 30, @gathering.processed_via_dandelion
    assert_equal 1, payment.notifications.and(type: 'created_payment').count

    deliver_webhook(payload)
    deliver_webhook(session_payload(payment.session_id, type: 'checkout.session.async_payment_succeeded'))

    assert_equal 200, last_response.status
    assert_equal 30, membership_of(member).paid
    assert_equal 30, @gathering.reload.balance
    assert_equal 1, payment.notifications.count
  end

  test 'a payment completed by two deliveries at once is credited once' do
    create_paying_gathering
    member = create_member
    payment = create_unpaid_payment(membership_of(member), amount: 30)

    # Each delivery found the payment not yet completed before either completed it
    first = Payment.find(payment.id)
    second = Payment.find(payment.id)
    first.payment_completed!
    second.payment_completed!

    assert payment.reload.payment_completed?
    assert_equal 30, membership_of(member).paid
    assert_equal 30, @gathering.reload.balance
    assert_equal 1, payment.notifications.count
  end

  test 'a session not yet paid completes nothing until its async payment succeeds' do
    create_paying_gathering
    payment = create_unpaid_payment(membership_of(create_member))

    deliver_webhook(session_payload(payment.session_id, payment_status: 'unpaid'))
    assert_equal 200, last_response.status
    assert_uncredited(payment)

    deliver_webhook(session_payload(payment.session_id, type: 'checkout.session.expired', payment_status: 'paid'))
    assert_uncredited(payment)

    deliver_webhook(session_payload(payment.session_id, type: 'checkout.session.async_payment_succeeded'))
    assert payment.reload.payment_completed?
    assert_equal 10, payment.membership.reload.paid
  end

  test 'a bad signature, an unknown session or another gathering\'s session changes nothing' do
    create_paying_gathering
    payment = create_unpaid_payment(membership_of(create_member))
    other_gathering = FactoryBot.create(:gathering, account: FactoryBot.create(:account), stripe_endpoint_secret: 'whsec_other')
    other_payment = create_unpaid_payment(other_gathering.memberships.first)

    deliver_webhook(session_payload(payment.session_id), secret: 'whsec_wrong')
    assert_equal 200, last_response.status
    deliver_webhook(session_payload(payment.session_id), secret: 'whsec_other')
    assert_equal 200, last_response.status
    deliver_webhook(session_payload('cs_unknown'))
    assert_equal 200, last_response.status
    # Signed for this gathering, but the session is another gathering's
    deliver_webhook(session_payload(other_payment.session_id))
    assert_equal 200, last_response.status

    assert_uncredited(payment)
    assert_uncredited(other_payment)
  end

  test 'a failure completing a payment is reported, and Stripe is told 200' do
    create_paying_gathering
    member = create_member
    payment = create_unpaid_payment(membership_of(member))
    # The member left before Stripe's webhook came
    membership_of(member).destroy

    reported = []
    ErrorReporting.stub(:capture_exception, ->(e, **) { reported << e }) do
      deliver_webhook(session_payload(payment.session_id))
    end

    assert_equal 200, last_response.status
    assert_equal 1, reported.count
    assert_kind_of NoMethodError, reported.first
  end

  # Checking on a payment

  test 'the payer and the gathering\'s admins see whether a payment is complete, and no other member' do
    create_paying_gathering
    member = create_member
    payment = create_unpaid_payment(membership_of(member))
    path = gathering_path("/payments/#{payment.id}")

    sign_in_with_rack(member)
    get path
    assert_equal 200, last_response.status
    assert_equal({ 'id' => payment.id.to_s, 'payment_completed' => false }, JSON.parse(last_response.body))

    payment.payment_completed!
    sign_in_with_rack(@account)
    get path
    assert_equal 200, last_response.status
    assert_equal({ 'id' => payment.id.to_s, 'payment_completed' => true }, JSON.parse(last_response.body))

    sign_in_with_rack(create_member(name: 'Another Member'))
    get path
    assert_equal 403, last_response.status

    sign_in_with_rack(FactoryBot.create(:account))
    header 'X-Requested-With', 'XMLHttpRequest'
    get path
    assert_equal 403, last_response.status
  end

  test 'another gathering\'s payment is not found under this gathering' do
    create_paying_gathering
    other_gathering = FactoryBot.create(:gathering, account: @account)
    other_payment = create_unpaid_payment(other_gathering.memberships.first)
    sign_in_with_rack(@account)

    get gathering_path("/payments/#{other_payment.id}")

    assert_equal 404, last_response.status
  end

  # EVM

  def evm_transfers(transfers, &)
    Gathering.stub(:evm_transactions, ->(address) { address == EVM_ADDRESS ? transfers : [] }, &)
  end

  test 'an EVM payment asks for its amount plus its secret in millionths, and completes once that arrives' do
    create_gathering(currency: 'BREAD', evm_address: EVM_ADDRESS)
    member = create_member
    sign_in_with_rack(member)

    post_pay(payment_method: 'evm', amount: '20')

    assert_equal 200, last_response.status, last_response.body
    payment = membership_of(member).payments.first
    json = JSON.parse(last_response.body)
    assert_match(/\A[1-9]{4}\z/, payment.evm_secret)
    assert_equal payment.evm_secret, json['evm_secret']
    assert_equal 20, payment.amount
    assert_equal 'BREAD', payment.currency
    assert_equal 20 + (payment.evm_secret.to_d / 1_000_000), payment.evm_amount
    assert_equal (payment.evm_amount * (10**18)).to_i.to_s, json['wei']
    assert_equal payment.id.to_s, json['payment_id']
    assert_equal ((payment.created_at + 1.hour).to_r * 1000).floor.to_s, json['payment_expiry'] # in milliseconds

    path = gathering_path("/payments/#{payment.id}")
    # The amount without the secret, the right amount in another token, or nothing yet
    evm_transfers([['BREAD', 20.0], ['CUSD', payment.evm_amount.to_f]]) { get path }
    assert_equal false, JSON.parse(last_response.body)['payment_completed']
    assert_equal 0, membership_of(member).paid

    # As Blockscout gives it: a float, from the transfer's value and decimals
    transfer = ['BREAD', (payment.evm_amount * (10**18)).to_i.to_f / (10**18)]
    evm_transfers([transfer]) { get path }
    assert_equal true, JSON.parse(last_response.body)['payment_completed']
    assert_equal 20, membership_of(member).paid

    # The transfer is still in the list next time
    evm_transfers([transfer]) { get path }
    assert_equal 20, membership_of(member).paid
  end
end
