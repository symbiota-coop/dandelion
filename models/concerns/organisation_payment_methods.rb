module OrganisationPaymentMethods
  extend ActiveSupport::Concern

  included do
    # Stripe: Connect OAuth, API keys, Checkout, and platform contributions
    field :stripe_connect_json, type: String
    field :stripe_account_json, type: String
    field :stripe_client_id, type: String
    field :stripe_endpoint_secret, type: String
    field :stripe_pk, type: String
    field :stripe_sk, type: String
    field :stripe_customer_id, type: String
    field :card_last4, type: String
    field :billing_address_collection, type: Mongoid::Boolean
    field :tax_rate_id, type: String

    # Mollie
    field :mollie_api_key, type: String

    # GoCardless: Instant Bank Pay, instalments, and monthly-donor subscriptions
    field :gocardless_access_token, type: String
    field :gocardless_endpoint_secret, type: String
    field :gocardless_filter, type: String
    field :gocardless_instant_bank_pay, type: Mongoid::Boolean
    field :gocardless_instalments, type: Mongoid::Boolean
    field :gocardless_subscriptions, type: Mongoid::Boolean

    # EVM (crypto)
    field :evm_address, type: String

    # Open Collective
    field :oc_slug, type: String

    validates_format_of :stripe_sk, with: /\A[a-z0-9_]+\z/i, allow_nil: true
    validates_format_of :stripe_pk, with: /\A[a-z0-9_]+\z/i, allow_nil: true

    before_validation do
      %w[mollie_api_key gocardless_access_token gocardless_endpoint_secret evm_address oc_slug].each do |f|
        send("#{f}=", send(f).strip) if send(f)
      end

      errors.add(:tax_rate_id, 'must start with txr_') if tax_rate_id && !tax_rate_id.starts_with?('txr_')

      if Padrino.env == :production && account && !account.admin?
        errors.add(:stripe_sk, 'must start with sk_live_') if stripe_sk && !stripe_sk.starts_with?('sk_live_')
        errors.add(:stripe_pk, 'must start with pk_live_') if stripe_pk && !stripe_pk.starts_with?('pk_live_')
      end
      errors.add(:stripe_sk, 'must be present if Stripe public key is present') if stripe_pk && !stripe_sk

      if mollie_api_key.present? && !mollie_api_key.match?(/\A(live|test)_[A-Za-z0-9]+\z/)
        errors.add(:mollie_api_key, 'must start with live_ or test_')
      end
      if Padrino.env == :production && account && !account.admin? && mollie_api_key && !mollie_api_key.starts_with?('live_')
        errors.add(:mollie_api_key, 'must start with live_')
      end

      errors.add(:gocardless_instant_bank_pay, 'requires GoCardless webhook secret') if gocardless_instant_bank_pay && !gocardless_endpoint_secret
      errors.add(:gocardless_instalments, 'requires GoCardless webhook secret') if gocardless_instalments && !gocardless_endpoint_secret
    end
  end

  class_methods do
    def payment_human_attribute_names
      {
        stripe_client_id: 'Stripe client ID',
        stripe_endpoint_secret: 'Stripe endpoint secret',
        stripe_pk: 'Stripe public key',
        stripe_sk: 'Stripe secret key',
        mollie_api_key: 'Mollie API key',
        gocardless_access_token: 'GoCardless access token',
        gocardless_endpoint_secret: 'GoCardless webhook secret',
        gocardless_instant_bank_pay: 'Enable GoCardless Instant Bank Pay',
        gocardless_instalments: 'Enable GoCardless Instalments',
        gocardless_subscriptions: 'Register people with active GoCardless subscriptions as monthly donors',
        evm_address: 'EVM address',
        oc_slug: 'Open Collective slug',
        tax_rate_id: 'Stripe tax rate ID'
      }
    end

    def payment_hints
      {
        stripe_pk: '<code>Developers</code> > <code>API keys</code> > <code>Publishable key</code>. Starts <code>pk_live_</code>',
        stripe_sk: '<code>Developers</code> > <code>API keys</code> > <code>Secret key</code>. Starts <code>sk_live_</code>',
        stripe_endpoint_secret: '<code>Developers</code> > <code>Webhooks</code> > <code>Signing secret</code>. Starts <code>whsec_</code>',
        stripe_client_id: 'Used for automated revenue sharing. <code>Settings</code> > <code>Connect</code> > <code>Live mode client ID</code>. Starts <code>ca_</code>',
        mollie_api_key: '<code>Developers</code> > <code>API keys</code>. Starts <code>live_</code>. Dandelion sends a webhook URL with each payment, so you do not need to add a webhook in the Mollie Dashboard.',
        gocardless_instant_bank_pay: 'Shown at checkout for GBP and EUR events only (UK and supported Eurozone countries)',
        gocardless_instalments: 'Shown at checkout for GBP and EUR events only. Set the number of instalments on each event.',
        evm_address: 'Ethereum-compatible wallet address for receiving tokens via EVM networks',
        oc_slug: 'Open Collective organisation slug',
        tax_rate_id: 'Stripe tax rate ID to apply to ticket purchases'
      }
    end
  end
end
