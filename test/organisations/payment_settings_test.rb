require_relative '../test_config'

# What an organisation's payment settings may be set to (OrganisationPaymentMethods), tested on the model. In
# production, an organisation whose account isn't a site admin can only use live keys
class OrganisationPaymentSettingsTest < ActiveSupport::TestCase
  # Each of attrs_and_errors' attributes, set on a fresh copy of @organisation, refused with its error, and the
  # organisation's settings left as they were
  def assert_refusals(attrs_and_errors)
    before = Organisation.find(@organisation.id).attributes
    attrs_and_errors.each do |attrs, (attribute, message)|
      organisation = Organisation.find(@organisation.id)
      organisation.assign_attributes(attrs)
      refute organisation.save, attrs.inspect
      assert_includes organisation.errors[attribute], message, attrs.inspect
    end
    assert_equal before.except('updated_at'), Organisation.find(@organisation.id).attributes.except('updated_at')
  end

  def assert_saves(attrs)
    organisation = Organisation.find(@organisation.id)
    assert organisation.update(attrs), organisation.errors.full_messages.to_sentence
    organisation = Organisation.find(@organisation.id)
    attrs.each { |attribute, value| assert_equal value, organisation.send(attribute), attribute }
  end

  # Validation only: in production, saving Stripe keys sets up their webhook with Stripe (StripeWebhooks)
  def assert_accepted(attrs)
    organisation = Organisation.find(@organisation.id)
    organisation.assign_attributes(attrs)
    assert organisation.valid?, organisation.errors.full_messages.to_sentence
  end

  test 'a tax rate starts with txr_' do
    create_organisation
    assert_refusals({ tax_rate_id: 'tax_123' } => [:tax_rate_id, 'must start with txr_'])
    assert_saves(tax_rate_id: 'txr_123')
  end

  test "in production, an organisation's Stripe keys are live and come as a pair, unless its account is a site admin" do
    create_organisation(stripe_sk: nil, stripe_pk: nil)
    Padrino.stub(:env, :production) do
      assert_refusals(
        { stripe_sk: 'sk_test_abc' } => [:stripe_sk, 'must start with sk_live_'],
        { stripe_sk: 'sk_live_abc', stripe_pk: 'pk_test_abc' } => [:stripe_pk, 'must start with pk_live_'],
        { stripe_pk: 'pk_live_abc' } => [:stripe_sk, 'must be present if Stripe public key is present']
      )
      assert_accepted(stripe_sk: 'sk_live_abc', stripe_pk: 'pk_live_abc')

      @account.set(admin: true)
      assert_accepted(stripe_sk: 'sk_test_abc', stripe_pk: 'pk_test_abc')
      # The pair is still needed
      assert_refusals({ stripe_pk: 'pk_test_abc' } => [:stripe_sk, 'must be present if Stripe public key is present'])
    end

    # Test keys are fine outside production
    @account.set(admin: false)
    assert_saves(stripe_sk: 'sk_test_def', stripe_pk: 'pk_test_def')
  end

  test "in production, an organisation's Mollie key is live and PayPal isn't in sandbox mode, unless its account is a site admin" do
    create_organisation(stripe_sk: nil, stripe_pk: nil)
    Padrino.stub(:env, :production) do
      assert_refusals(
        { mollie_api_key: 'test_abc' } => [:mollie_api_key, 'must start with live_'],
        { mollie_api_key: 'key_abc' } => [:mollie_api_key, 'must start with live_ or test_'],
        { paypal_client_id: 'client', paypal_secret: 'secret', paypal_sandbox: true } => [:paypal_sandbox, 'cannot be used in production']
      )
      assert_accepted(mollie_api_key: 'live_abc', paypal_client_id: 'client', paypal_secret: 'secret', paypal_sandbox: false)

      @account.set(admin: true)
      assert_accepted(mollie_api_key: 'test_abc', paypal_sandbox: true)
    end

    @account.set(admin: false)
    assert_saves(mollie_api_key: 'test_def', paypal_sandbox: true)
  end

  test "an organisation's PayPal secret and client ID come together" do
    create_organisation
    assert_refusals(
      { paypal_secret: 'secret' } => [:paypal_client_id, 'must be present if PayPal secret is present'],
      { paypal_client_id: 'client' } => [:paypal_secret, 'must be present if PayPal client ID is present']
    )
    assert_saves(paypal_client_id: 'client', paypal_secret: 'secret')
  end

  test "GoCardless's instant bank pay and instalments need its webhook secret" do
    create_organisation(gocardless_access_token: 'gc_token')
    assert_refusals(
      { gocardless_instant_bank_pay: true } => [:gocardless_instant_bank_pay, 'requires GoCardless webhook secret'],
      { gocardless_instalments: true } => [:gocardless_instalments, 'requires GoCardless webhook secret']
    )
    assert_saves(gocardless_endpoint_secret: 'whsec', gocardless_instant_bank_pay: true, gocardless_instalments: true)
  end

  test "an organisation's Patreon details are given all together or not at all" do
    create_organisation
    fields = %i[patreon_client_id patreon_client_secret patreon_refresh_token]
    fields.each do |given|
      organisation = Organisation.find(@organisation.id)
      organisation.assign_attributes(given => 'value')
      refute organisation.save, given.to_s
      (fields - [given]).each do |missing|
        assert_equal ['must be provided if other Patreon details have been provided'], organisation.errors[missing], "#{given}: #{missing}"
      end
      assert_empty organisation.errors[given]
    end
    assert_equal([nil, nil, nil], fields.map { |f| Organisation.find(@organisation.id).send(f) })

    assert_saves(patreon_client_id: 'client', patreon_client_secret: 'secret', patreon_refresh_token: 'refresh')
  end
end
