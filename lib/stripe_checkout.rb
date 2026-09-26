module StripeCheckout
  PAID_EVENT_TYPES = %w[checkout.session.completed checkout.session.async_payment_succeeded].freeze
  PAID_STATUSES = %w[paid no_payment_required].freeze

  def self.paid_session(event)
    return unless PAID_EVENT_TYPES.include?(event['type'])

    session = event['data']['object']
    session if PAID_STATUSES.include?(session['payment_status'])
  end
end
