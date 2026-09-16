module TicketPaymentMethods
  extend ActiveSupport::Concern

  included do
    # Stripe
    field :session_id, type: String
    field :payment_intent, type: String

    # GoCardless
    field :gocardless_payment_request_id, type: String
    field :gocardless_billing_request_id, type: String
    field :gocardless_payment_id, type: String

    # Mollie
    field :mollie_payment_id, type: String

    # PayPal
    field :paypal_order_id, type: String
    field :paypal_capture_id, type: String
  end
end
