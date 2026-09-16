module OrderPaymentMethods
  extend ActiveSupport::Concern

  included do
    # Stripe
    field :session_id, type: String
    field :payment_intent, type: String
    field :transfer_id, type: String

    # Coinbase
    field :coinbase_checkout_id, type: String

    # GoCardless
    field :gocardless_payment_request_id, type: String
    field :gocardless_payment_id, type: String
    field :gocardless_billing_request_id, type: String

    # Mollie
    field :mollie_payment_id, type: String

    # PayPal
    field :paypal_order_id, type: String
    field :paypal_capture_id, type: String

    # EVM (crypto)
    field :evm_secret, type: String
    field :evm_value, type: BigDecimal

    # Open Collective
    field :oc_secret, type: String

    validates_uniqueness_of :session_id, :payment_intent, :coinbase_checkout_id, :mollie_payment_id, :paypal_order_id, allow_nil: true
    validates_uniqueness_of :evm_secret, scope: :evm_value, allow_nil: true

    before_validation do
      self.evm_value = value.to_d + evm_offset if evm_secret && !evm_value
    end
  end

  def evm_offset
    evm_secret.to_d / 1e6
  end

  def persist_gocardless_payment_id(payment_id)
    return if gocardless_payment_id.present? || payment_id.blank?

    set(gocardless_payment_id: payment_id)
    tickets.each do |ticket|
      ticket.update_attributes!(gocardless_payment_id: payment_id)
    end
  end

  def persist_paypal_capture_id(capture_id)
    return if paypal_capture_id.present? || capture_id.blank?

    set(paypal_capture_id: capture_id)
    tickets.each do |ticket|
      ticket.update_attributes!(paypal_capture_id: capture_id)
    end
  end

  def create_gocardless_instalment_schedule
    client = GoCardlessPro::Client.new(access_token: event.organisation.gocardless_access_token)
    billing_request = client.billing_requests.get(gocardless_billing_request_id)
    mandate_id = billing_request.links.mandate_request_mandate if billing_request&.status == 'fulfilled'
    raise 'fulfilled billing request did not include a mandate' if mandate_id.blank?

    total_pence = (value * 100).round
    count = event.gocardless_instalment_count.to_i
    base = total_pence / count
    remainder = total_pence % count
    amounts = Array.new(count) { |i| i.zero? ? base + remainder : base }

    begin
      client.instalment_schedules.create_with_schedule(
        params: {
          name: description.truncate(100),
          currency: currency,
          total_amount: total_pence,
          instalments: {
            interval_unit: 'monthly',
            interval: 1,
            amounts: amounts
          },
          links: { mandate: mandate_id }
        },
        headers: { 'Idempotency-Key' => "dandelion-order-#{id}-instalment-schedule" }
      )
      true
    rescue GoCardlessPro::InvalidStateError => e
      return true if e.try(:idempotent_creation_conflict?)
      return false if e.message.to_s.include?('cancelled')

      raise
    end
  end
end
