require_relative '../test_config'

# Paying Dandelion itself: organisations contributing (and saving a card for auto top-ups), people donating once or
# monthly, and the webhooks from Dandelion's own Stripe account that complete them
class PaymentsDandelionContributionsTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  ORGANISATIONS_SECRET = 'whsec_organisations_test'.freeze
  ACCOUNTS_SECRET = 'whsec_accounts_test'.freeze

  # Stripe

  # Stubs Stripe::Checkout::Session.create for the block, answering with session_id, and returns the calls it got as
  # [params, opts] pairs
  def stub_checkout_session(session_id: "cs_#{SecureRandom.hex(4)}", payment_intent: "pi_#{SecureRandom.hex(4)}", &)
    calls = []
    Stripe::Checkout::Session.stub(:create, proc { |params, opts|
      calls << [params, opts]
      api_object(id: session_id, payment_intent: payment_intent)
    }, &)
    calls
  end

  def dandelion_stripe_opts
    { api_key: ENV.fetch('STRIPE_SK'), stripe_version: ENV.fetch('STRIPE_API_VERSION') }
  end

  # An organisation with keys and a Stripe Connect account of its own, none of which paying Dandelion should use
  def create_contributing_organisation
    create_organisation(currency: 'GBP', stripe_pk: 'pk_organisation_own', stripe_sk: 'sk_organisation_own',
                        stripe_connect_json: { 'stripe_user_id' => 'acct_organisation_own' }.to_json)
  end

  # Webhooks

  # Posts payload to path as Stripe would, signed with secret, while the endpoint's secret (env) is expected
  def deliver_webhook(path, env, expected_secret, payload, secret: expected_secret)
    timestamp = Time.now
    signature = Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret)
    with_env({ env => expected_secret }) do
      header 'Stripe-Signature', Stripe::Webhook::Signature.generate_header(timestamp, signature)
      header 'Content-Type', 'application/json'
      post path, payload
    end
  end

  def deliver_organisations_webhook(payload, secret: ORGANISATIONS_SECRET)
    deliver_webhook('/organisations/stripe_webhook', 'STRIPE_ENDPOINT_SECRET_ORGANISATIONS', ORGANISATIONS_SECRET, payload, secret: secret)
  end

  def deliver_accounts_webhook(payload, secret: ACCOUNTS_SECRET)
    deliver_webhook('/accounts/stripe_webhook', 'STRIPE_ENDPOINT_SECRET_ACCOUNTS', ACCOUNTS_SECRET, payload, secret: secret)
  end

  def event_payload(type, object)
    { id: "evt_#{SecureRandom.hex(4)}", object: 'event', type: type, data: { object: object } }.to_json
  end

  def checkout_payload(session_id, type: 'checkout.session.completed', payment_status: 'paid')
    event_payload(type, { id: session_id, object: 'checkout.session', payment_status: payment_status })
  end

  def subscription_payload(type, subscription_id: 'sub_monthly', status: 'active', customer: 'cus_donor', amount: 1000)
    event_payload(type, { id: subscription_id, object: 'subscription', status: status, customer: customer,
                          plan: { id: 'plan_monthly', object: 'plan', amount: amount, currency: 'gbp' } })
  end

  # The queued jobs that would email Dandelion's admins about the contribution with this session id
  def notification_jobs(session_id)
    Delayed::Job.all.select do |job|
      job.handler.match?(/^method_name: :send_notification(_without_delay)?$/) && job.handler.include?("session_id: #{session_id}\n")
    end
  end

  # Delivers payload to path twice at once, as Stripe can, with each delivery looking up the contribution (model) at the
  # same moment
  def deliver_twice_at_once(path, env, secret, payload, model)
    looked_up = Queue.new
    find_by = model.method(:find_by)
    timestamp = Time.now
    signature = Stripe::Webhook::Signature.generate_header(timestamp, Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret))
    with_env({ env => secret }) do
      lookup = proc do |*args, **kwargs|
        found = find_by.call(*args, **kwargs)
        looked_up << true
        deadline = Time.now + 2
        sleep 0.01 until looked_up.size >= 2 || Time.now > deadline
        found
      end
      model.stub(:find_by, lookup) do
        Array.new(2) do
          Thread.new do
            session = Rack::Test::Session.new(app)
            session.header 'Stripe-Signature', signature
            session.header 'Content-Type', 'application/json'
            session.post path, payload
            session.last_response.status
          end
        end.map(&:value)
      end
    end
  end

  def run_jobs
    recorded_emails { Delayed::Job.all.each(&:invoke_job) }
  end

  # Organisations paying

  test 'an organisation admin pays its contribution through Dandelion\'s own Stripe account, for the amount and currency asked' do
    create_contributing_organisation
    sign_in_with_rack(@account)

    header 'Accept', 'application/json'
    calls = stub_checkout_session(session_id: 'cs_org', payment_intent: 'pi_org') do
      post "/o/#{@organisation.slug}/pay", amount: '12.345', currency: 'EUR', payment_method: 'stripe'
    end

    assert_equal 200, last_response.status
    assert_equal 'cs_org', JSON.parse(last_response.body)['session_id']
    assert_equal 1, calls.length
    params, opts = calls.first
    assert_equal dandelion_stripe_opts, opts
    line_item = params[:line_items].sole
    assert_equal 1235, line_item[:amount]
    assert_equal 'EUR', line_item[:currency]
    assert_equal 1, line_item[:quantity]
    assert_equal @account.email, params[:customer_email]
    assert_equal({ de_contribution_type: 'organisation_contribution', de_organisation_id: @organisation.id.to_s }, params[:payment_intent_data][:metadata])

    contribution = @organisation.organisation_contributions.sole
    assert_in_delta 12.345, contribution.amount
    assert_equal 'EUR', contribution.currency
    assert_equal 'cs_org', contribution.session_id
    assert_equal 'pi_org', contribution.payment_intent
    refute contribution.payment_completed?
  end

  test 'paying an organisation\'s contribution needs an amount above zero' do
    create_contributing_organisation
    sign_in_with_rack(@account)

    header 'Accept', 'application/json'
    calls = stub_checkout_session do
      ['', '0', '-5', 'abc'].each do |amount|
        post "/o/#{@organisation.slug}/pay", amount: amount, currency: 'GBP', payment_method: 'stripe'
        assert_equal 400, last_response.status, amount
      end
      post "/o/#{@organisation.slug}/pay", currency: 'GBP', payment_method: 'stripe'
      assert_equal 400, last_response.status
    end

    assert_empty calls
    assert_equal 0, @organisation.organisation_contributions.count
  end

  test 'only an organisation\'s admins can pay its contribution or see its Contribute page' do
    create_contributing_organisation
    member = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: member)

    calls = stub_checkout_session do
      # Signed out
      post "/o/#{@organisation.slug}/pay", amount: '10', currency: 'GBP', payment_method: 'stripe'
      assert_equal 302, last_response.status

      sign_in_with_rack(member)
      post "/o/#{@organisation.slug}/pay", amount: '10', currency: 'GBP', payment_method: 'stripe'
      assert_equal 302, last_response.status
      assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path

      header 'X-Requested-With', 'XMLHttpRequest'
      post "/o/#{@organisation.slug}/pay", amount: '10', currency: 'GBP', payment_method: 'stripe'
      assert_equal 403, last_response.status
    end
    assert_empty calls
    assert_equal 0, @organisation.organisation_contributions.count

    header 'X-Requested-With', nil
    get "/o/#{@organisation.slug}/contribute"
    assert_equal 302, last_response.status
    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path

    sign_in_with_rack(@account)
    get "/o/#{@organisation.slug}/contribute"
    assert_equal 200, last_response.status
  end

  test 'paying, saving a card for or turning off auto top-ups for an organisation that does not exist is not found' do
    create_contributing_organisation
    sign_in_with_rack(@account)

    calls = stub_checkout_session do
      post '/o/no-such-organisation/pay', amount: '10', currency: 'GBP', payment_method: 'stripe'
      assert_equal 404, last_response.status
      post '/o/no-such-organisation/stripe_setup'
      assert_equal 404, last_response.status
    end
    assert_empty calls
    get '/o/no-such-organisation/stripe_setup_complete', session_id: 'cs_setup'
    assert_equal 404, last_response.status
    post '/o/no-such-organisation/clear_stripe_customer_id'
    assert_equal 404, last_response.status
  end

  # Saving a card for auto top-ups

  test 'an organisation admin starts saving a card in a setup session on Dandelion\'s own Stripe account' do
    create_contributing_organisation
    @organisation.set(currency: 'EUR')
    sign_in_with_rack(@account)

    header 'Accept', 'application/json'
    calls = stub_checkout_session(session_id: 'cs_setup') { post "/o/#{@organisation.slug}/stripe_setup" }

    assert_equal 200, last_response.status
    assert_equal 'cs_setup', JSON.parse(last_response.body)['session_id']
    params, opts = calls.sole
    assert_equal dandelion_stripe_opts, opts
    assert_equal 'setup', params[:mode]
    assert_equal 'EUR', params[:currency]
    assert_equal @organisation.id.to_s, params[:client_reference_id]
    assert_includes params[:success_url], "/o/#{@organisation.slug}/stripe_setup_complete?session_id={CHECKOUT_SESSION_ID}"
  end

  # Stubs the setup session's retrieval as Stripe would answer it, and the setup intent and payment method it names,
  # returning the [id, opts] each retrieve got
  def stub_setup_complete(session, &)
    retrieved = []
    Stripe::Checkout::Session.stub(:retrieve, proc { |id, opts|
      retrieved << [id, opts]
      session
    }) do
      Stripe::SetupIntent.stub(:retrieve, proc { |id, opts|
        retrieved << [id, opts]
        api_object(payment_method: 'pm_card')
      }) do
        Stripe::PaymentMethod.stub(:retrieve, proc { |id, opts|
          retrieved << [id, opts]
          api_object(id: 'pm_card', card: api_object(last4: '4242'))
        }, &)
      end
    end
    retrieved
  end

  def setup_session(organisation, mode: 'setup', client_reference_id: organisation.id.to_s)
    api_object(mode: mode, client_reference_id: client_reference_id, setup_intent: 'seti_card', customer: 'cus_organisation')
  end

  test 'completing card setup saves the customer and card, and makes the organisation paid up' do
    create_contributing_organisation
    create_event(fixed_contribution_gbp: 10)
    @organisation.set(paid_up: false)
    sign_in_with_rack(@account)

    charged = []
    retrieved = Stripe::Customer.stub(:list_payment_methods, [api_object(id: 'pm_card')]) do
      Stripe::PaymentIntent.stub(:create, proc { |params, opts|
        charged << [params, opts]
        api_object(id: 'pi_topup')
      }) do
        stub_setup_complete(setup_session(@organisation)) do
          get "/o/#{@organisation.slug}/stripe_setup_complete", session_id: 'cs_setup'
        end
      end
    end

    assert_equal 302, last_response.status
    assert_equal "/o/#{@organisation.slug}/contribute", URI(last_response.location).path
    assert_equal [['cs_setup', dandelion_stripe_opts], ['seti_card', dandelion_stripe_opts], ['pm_card', dandelion_stripe_opts]], retrieved
    @organisation.reload
    assert_equal 'cus_organisation', @organisation.stripe_customer_id
    assert_equal '4242', @organisation.card_last4
    assert @organisation.paid_up

    # The card is charged what's owed, on Dandelion's own account
    params, opts = charged.sole
    assert_equal dandelion_stripe_opts, opts
    assert_equal 1000, params[:amount]
    assert_equal 'GBP', params[:currency].to_s
    assert_equal 'cus_organisation', params[:customer]
    topup = @organisation.organisation_contributions.sole
    assert_in_delta 10, topup.amount
    assert topup.payment_completed?
  end

  test 'a setup session that is not this organisation\'s, or not a setup, saves nothing' do
    create_contributing_organisation
    other_organisation = FactoryBot.create(:organisation, account: FactoryBot.create(:account))
    sign_in_with_rack(@account)

    [setup_session(@organisation, client_reference_id: other_organisation.id.to_s), setup_session(@organisation, mode: 'payment')].each do |session|
      retrieved = stub_setup_complete(session) { get "/o/#{@organisation.slug}/stripe_setup_complete", session_id: 'cs_other' }
      assert_equal 400, last_response.status
      assert_equal 1, retrieved.length # only the session
    end

    assert_nil @organisation.reload.stripe_customer_id
    assert_nil @organisation.card_last4
  end

  test 'only an organisation\'s admins can save a card for it, or turn auto top-ups off' do
    create_contributing_organisation
    @organisation.set(stripe_customer_id: 'cus_saved')
    member = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: member)
    sign_in_with_rack(member)

    calls = stub_checkout_session { post "/o/#{@organisation.slug}/stripe_setup" }
    assert_equal 302, last_response.status
    assert_empty calls

    retrieved = stub_setup_complete(setup_session(@organisation)) { get "/o/#{@organisation.slug}/stripe_setup_complete", session_id: 'cs_setup' }
    assert_equal 302, last_response.status
    assert_empty retrieved

    post "/o/#{@organisation.slug}/clear_stripe_customer_id"
    assert_equal 302, last_response.status
    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
    assert_equal 'cus_saved', @organisation.reload.stripe_customer_id
  end

  test 'an organisation admin turns auto top-ups off, forgetting the saved customer' do
    create_contributing_organisation
    @organisation.set(stripe_customer_id: 'cus_saved')
    sign_in_with_rack(@account)

    post "/o/#{@organisation.slug}/clear_stripe_customer_id"

    assert_equal 302, last_response.status
    assert_equal "/o/#{@organisation.slug}/contribute", URI(last_response.location).path
    assert_nil @organisation.reload.stripe_customer_id
  end

  # Organisations webhook

  def create_pending_organisation_contribution(amount: 10, session_id: "cs_#{SecureRandom.hex(4)}")
    create_contributing_organisation
    create_event(fixed_contribution_gbp: 10)
    @organisation.set(paid_up: false)
    contribution = @organisation.organisation_contributions.create!(amount: amount, currency: 'GBP', session_id: session_id, payment_intent: 'pi_org', payment_completed: false)
    Delayed::Job.delete_all # the update_paid_up its creation queued
    contribution
  end

  test 'a paid contribution completes once, tells Dandelion\'s admins and makes the organisation paid up' do
    contribution = create_pending_organisation_contribution

    deliver_organisations_webhook(checkout_payload(contribution.session_id))

    assert_equal 200, last_response.status
    assert contribution.reload.payment_completed?
    assert_equal 1, notification_jobs(contribution.session_id).count
    refute @organisation.reload.paid_up # until the queued update runs

    run_jobs
    @organisation.reload
    assert @organisation.paid_up
    assert_in_delta 10, @organisation.contribution_paid_gbp_cache
    assert_in_delta 10, @organisation.contribution_requested_gbp_cache
  end

  test 'the same contribution webhook delivered again completes and notifies once' do
    contribution = create_pending_organisation_contribution
    payload = checkout_payload(contribution.session_id)

    deliver_organisations_webhook(payload)
    deliver_organisations_webhook(payload)
    deliver_organisations_webhook(checkout_payload(contribution.session_id, type: 'checkout.session.async_payment_succeeded'))

    assert_equal 200, last_response.status
    assert_equal 1, @organisation.organisation_contributions.count
    assert_equal 1, notification_jobs(contribution.session_id).count
  end

  test 'two deliveries of a paid contribution at once complete and notify once' do
    contribution = create_pending_organisation_contribution

    statuses = deliver_twice_at_once('/organisations/stripe_webhook', 'STRIPE_ENDPOINT_SECRET_ORGANISATIONS', ORGANISATIONS_SECRET,
                                     checkout_payload(contribution.session_id), OrganisationContribution)

    assert_equal [200, 200], statuses
    assert contribution.reload.payment_completed?
    assert_equal 1, notification_jobs(contribution.session_id).count
  end

  test 'a contribution not yet paid waits for its async payment to succeed' do
    contribution = create_pending_organisation_contribution

    deliver_organisations_webhook(checkout_payload(contribution.session_id, payment_status: 'unpaid'))
    assert_equal 200, last_response.status
    refute contribution.reload.payment_completed?
    assert_equal 0, notification_jobs(contribution.session_id).count

    deliver_organisations_webhook(checkout_payload(contribution.session_id, type: 'checkout.session.async_payment_succeeded'))
    assert contribution.reload.payment_completed?
    assert_equal 1, notification_jobs(contribution.session_id).count
  end

  test 'contribution webhooks for unknown sessions, other events or a person\'s donation change nothing' do
    contribution = create_pending_organisation_contribution
    donation = AccountContribution.create!(amount: 5, currency: 'GBP', session_id: 'cs_donation', payment_completed: false)

    [checkout_payload('cs_unknown'), checkout_payload('cs_donation'),
     checkout_payload(contribution.session_id, type: 'checkout.session.expired'),
     event_payload('payment_intent.succeeded', { id: 'pi_org', object: 'payment_intent', status: 'succeeded' })].each do |payload|
      deliver_organisations_webhook(payload)
      assert_equal 200, last_response.status
    end

    refute contribution.reload.payment_completed?
    refute donation.reload.payment_completed?
    assert_equal 0, Delayed::Job.count
  end

  test 'a contribution webhook with a bad signature, or a body that is not JSON, is turned away and completes nothing' do
    contribution = create_pending_organisation_contribution

    deliver_organisations_webhook(checkout_payload(contribution.session_id), secret: 'whsec_wrong')
    assert_equal 200, last_response.status
    deliver_organisations_webhook(checkout_payload(contribution.session_id), secret: ACCOUNTS_SECRET)
    assert_equal 200, last_response.status
    deliver_organisations_webhook('not json')
    assert_equal 200, last_response.status

    refute contribution.reload.payment_completed?
    assert_equal 0, Delayed::Job.count
  end

  # People paying

  test 'someone signed in donates through Dandelion\'s own Stripe account, for the amount and currency asked' do
    account = FactoryBot.create(:account)
    sign_in_with_rack(account)

    header 'Accept', 'application/json'
    calls = stub_checkout_session(session_id: 'cs_donation', payment_intent: 'pi_donation') do
      post '/accounts/pay', amount: '7.5', currency: 'USD', payment_method: 'stripe', account_id: account.id.to_s, source: 'donate'
    end

    assert_equal 200, last_response.status
    assert_equal 'cs_donation', JSON.parse(last_response.body)['session_id']
    params, opts = calls.sole
    assert_equal dandelion_stripe_opts, opts
    line_item = params[:line_items].sole
    assert_equal 750, line_item[:amount]
    assert_equal 'USD', line_item[:currency]
    assert_equal 1, line_item[:quantity]
    assert_equal account.email, params[:customer_email]
    assert_equal({ de_contribution_type: 'account_donation', de_account_id: account.id.to_s, de_source: 'donate' }, params[:payment_intent_data][:metadata])

    contribution = account.account_contributions.sole
    assert_in_delta 7.5, contribution.amount
    assert_equal 'USD', contribution.currency
    assert_equal 'donate', contribution.source
    assert_equal 'cs_donation', contribution.session_id
    assert_equal 'pi_donation', contribution.payment_intent
    refute contribution.payment_completed?
  end

  test 'a donation names an account only when it is the one signed in' do
    account = FactoryBot.create(:account)
    someone_else = FactoryBot.create(:account)

    header 'Accept', 'application/json'
    calls = stub_checkout_session do
      # Signed out, naming an account
      post '/accounts/pay', amount: '5', currency: 'GBP', payment_method: 'stripe', account_id: someone_else.id.to_s
      assert_equal 200, last_response.status

      # Signed in, naming someone else
      sign_in_with_rack(account)
      header 'Accept', 'application/json'
      post '/accounts/pay', amount: '5', currency: 'GBP', payment_method: 'stripe', account_id: someone_else.id.to_s
      assert_equal 200, last_response.status
    end

    calls.each do |params, _opts|
      assert_nil params[:customer_email]
      assert_equal({ de_contribution_type: 'guest_donation' }, params[:payment_intent_data][:metadata])
    end
    assert_equal 2, AccountContribution.and(account_id: nil).count
    assert_equal 0, someone_else.account_contributions.count
    assert_equal 0, account.account_contributions.count
  end

  test 'a donation needs an amount above zero and a card' do
    header 'Accept', 'application/json'
    calls = stub_checkout_session do
      ['', '0', '-1'].each do |amount|
        post '/accounts/pay', amount: amount, currency: 'GBP', payment_method: 'stripe'
        assert_equal 400, last_response.status, amount
      end
      post '/accounts/pay', amount: '5', currency: 'GBP', payment_method: 'coinbase'
      assert_equal 400, last_response.status
      post '/accounts/pay', amount: '5', currency: 'GBP'
      assert_equal 400, last_response.status
    end

    assert_empty calls
    assert_equal 0, AccountContribution.count
  end

  test 'a donation from an event\'s page is linked to the event' do
    create_event

    header 'Accept', 'application/json'
    stub_checkout_session { post '/accounts/pay', amount: '5', currency: 'GBP', payment_method: 'stripe', source: "event:#{@event.id}" }

    assert_equal 200, last_response.status
    assert_equal @event, AccountContribution.all.sole.event
  end

  # Accounts webhook: one-off donations

  test 'a paid donation completes once and tells Dandelion\'s admins' do
    account = FactoryBot.create(:account)
    donation = account.account_contributions.create!(amount: 5, currency: 'GBP', session_id: 'cs_donation', payment_completed: false)
    payload = checkout_payload('cs_donation')

    deliver_accounts_webhook(payload)
    assert_equal 200, last_response.status
    assert donation.reload.payment_completed?
    assert_equal 1, notification_jobs('cs_donation').count

    deliver_accounts_webhook(payload)
    deliver_accounts_webhook(checkout_payload('cs_donation', type: 'checkout.session.async_payment_succeeded'))
    assert_equal 200, last_response.status
    assert_equal 1, AccountContribution.count
    assert_equal 1, notification_jobs('cs_donation').count
  end

  test 'two deliveries of a paid donation at once complete and notify once' do
    donation = AccountContribution.create!(amount: 5, currency: 'GBP', session_id: 'cs_donation', payment_completed: false)

    statuses = deliver_twice_at_once('/accounts/stripe_webhook', 'STRIPE_ENDPOINT_SECRET_ACCOUNTS', ACCOUNTS_SECRET,
                                     checkout_payload('cs_donation'), AccountContribution)

    assert_equal [200, 200], statuses
    assert donation.reload.payment_completed?
    assert_equal 1, notification_jobs('cs_donation').count
  end

  test 'a donation not yet paid waits for its async payment to succeed' do
    donation = AccountContribution.create!(amount: 5, currency: 'GBP', session_id: 'cs_donation', payment_completed: false)

    deliver_accounts_webhook(checkout_payload('cs_donation', payment_status: 'unpaid'))
    assert_equal 200, last_response.status
    refute donation.reload.payment_completed?

    deliver_accounts_webhook(checkout_payload('cs_donation', type: 'checkout.session.async_payment_succeeded'))
    assert donation.reload.payment_completed?
    assert_equal 1, notification_jobs('cs_donation').count
  end

  test 'donation webhooks for unknown sessions, other events or an organisation\'s contribution change nothing' do
    donation = AccountContribution.create!(amount: 5, currency: 'GBP', session_id: 'cs_donation', payment_completed: false)
    contribution = create_pending_organisation_contribution(session_id: 'cs_org')

    [checkout_payload('cs_unknown'), checkout_payload('cs_org'),
     checkout_payload('cs_donation', type: 'checkout.session.expired'),
     event_payload('invoice.paid', { id: 'in_1', object: 'invoice', status: 'paid' })].each do |payload|
      deliver_accounts_webhook(payload)
      assert_equal 200, last_response.status
    end

    refute donation.reload.payment_completed?
    refute contribution.reload.payment_completed?
    assert_equal 0, Delayed::Job.count
  end

  test 'a donation webhook with a bad signature is turned away and completes nothing' do
    donation = AccountContribution.create!(amount: 5, currency: 'GBP', session_id: 'cs_donation', payment_completed: false)

    deliver_accounts_webhook(checkout_payload('cs_donation'), secret: 'whsec_wrong')
    assert_equal 200, last_response.status
    deliver_accounts_webhook(checkout_payload('cs_donation'), secret: ORGANISATIONS_SECRET)
    assert_equal 200, last_response.status

    refute donation.reload.payment_completed?
    assert_equal 0, Delayed::Job.count
  end

  # Accounts webhook: monthly subscriptions

  # Stubs Stripe::Customer.retrieve to answer with email, returning the [id, opts] it got
  def stub_customer(email, &)
    retrieved = []
    Stripe::Customer.stub(:retrieve, proc { |id, opts|
      retrieved << [id, opts]
      api_object(id: id, email: email)
    }, &)
    retrieved
  end

  def create_donor
    FactoryBot.create(:account, admin: true) # to be told
    FactoryBot.create(:account, email: 'donor@example.com')
  end

  test 'a new monthly subscription makes its customer\'s account a monthly donor and tells Dandelion\'s admins' do
    donor = create_donor

    email = nil
    retrieved = stub_customer(' Donor@Example.com ') do
      email = recorded_email { deliver_accounts_webhook(subscription_payload('customer.subscription.created')) }
    end

    assert_equal 200, last_response.status
    assert_equal [['cus_donor', dandelion_stripe_opts]], retrieved
    assert_equal 'sub_monthly', donor.reload.stripe_subscription_id
    assert_equal "[Account] #{donor.name} created a subscription of 10 GBP per month", email.subject_line
  end

  test 'a subscription with its customer already expanded needs no lookup' do
    donor = create_donor

    retrieved = stub_customer('someone@example.com') do
      recorded_emails do
        deliver_accounts_webhook(subscription_payload('customer.subscription.created', customer: { id: 'cus_donor', object: 'customer', email: 'donor@example.com' }))
      end
    end

    assert_empty retrieved
    assert_equal 'sub_monthly', donor.reload.stripe_subscription_id
  end

  test 'a renewed or past due subscription keeps its account a monthly donor, without telling anyone' do
    donor = create_donor
    donor.set(stripe_subscription_id: 'sub_monthly')

    emails = recorded_emails do
      stub_customer('donor@example.com') do
        %w[active past_due unpaid].each do |status|
          deliver_accounts_webhook(subscription_payload('customer.subscription.updated', status: status))
          assert_equal 200, last_response.status
        end
      end
    end

    assert_equal 'sub_monthly', donor.reload.stripe_subscription_id
    assert_empty emails.select(&:subject_line)
  end

  test 'a second subscription replaces the first without telling anyone again' do
    donor = create_donor
    donor.set(stripe_subscription_id: 'sub_old')

    emails = recorded_emails do
      stub_customer('donor@example.com') { deliver_accounts_webhook(subscription_payload('customer.subscription.created', subscription_id: 'sub_new')) }
    end

    assert_equal 'sub_new', donor.reload.stripe_subscription_id
    assert_empty emails.select(&:subject_line)
  end

  test 'a subscription updated to cancelled ends its account\'s monthly donations, but not another subscription\'s' do
    donor = create_donor
    donor.set(stripe_subscription_id: 'sub_current')

    emails = recorded_emails do
      stub_customer('donor@example.com') do
        deliver_accounts_webhook(subscription_payload('customer.subscription.updated', subscription_id: 'sub_old', status: 'canceled'))
        assert_equal 'sub_current', donor.reload.stripe_subscription_id

        deliver_accounts_webhook(subscription_payload('customer.subscription.updated', subscription_id: 'sub_current', status: 'canceled'))
      end
    end

    assert_equal 200, last_response.status
    assert_nil donor.reload.stripe_subscription_id
    assert_empty emails.select(&:subject_line) # the deletion that follows tells them
  end

  test 'a deleted subscription ends its account\'s monthly donations and tells Dandelion\'s admins' do
    donor = create_donor
    donor.set(stripe_subscription_id: 'sub_monthly')
    other_donor = FactoryBot.create(:account, stripe_subscription_id: 'sub_other')

    email = recorded_email { deliver_accounts_webhook(subscription_payload('customer.subscription.deleted', status: 'canceled')) }

    assert_equal 200, last_response.status
    assert_nil donor.reload.stripe_subscription_id
    assert_equal 'sub_other', other_donor.reload.stripe_subscription_id
    assert_equal "[Account] #{donor.name} deleted a subscription of 10 GBP per month", email.subject_line
  end

  test 'subscriptions for no account, or not yet active, change nothing' do
    donor = create_donor

    emails = recorded_emails do
      stub_customer('stranger@example.com') { deliver_accounts_webhook(subscription_payload('customer.subscription.created')) }
      assert_equal 200, last_response.status
      stub_customer('donor@example.com') { deliver_accounts_webhook(subscription_payload('customer.subscription.created', status: 'incomplete')) }
      assert_equal 200, last_response.status
      deliver_accounts_webhook(subscription_payload('customer.subscription.deleted', subscription_id: 'sub_unknown'))
      assert_equal 200, last_response.status
    end

    assert_nil donor.reload.stripe_subscription_id
    assert_empty emails.select(&:subject_line)
  end

  test 'a subscription webhook with a bad signature is turned away and changes nothing' do
    donor = create_donor
    donor.set(stripe_subscription_id: 'sub_monthly')

    deliver_accounts_webhook(subscription_payload('customer.subscription.deleted', status: 'canceled'), secret: 'whsec_wrong')

    assert_equal 200, last_response.status
    assert_equal 'sub_monthly', donor.reload.stripe_subscription_id
  end
end
