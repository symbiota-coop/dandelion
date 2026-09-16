class EventPaymentMethod
  module Mollie
    def self.call(order:, event:, **)
      payment = ::Mollie::Payment.create(
        amount: amount_hash(order.total, order.currency),
        description: order.description.truncate(255),
        redirect_url: "#{ENV['BASE_URI']}/e/#{event.slug}?success=true&order_id=#{order.public_id}",
        cancel_url: "#{ENV['BASE_URI']}/e/#{event.slug}?cancelled=true",
        webhook_url: "#{ENV['BASE_URI']}/o/#{event.organisation.slug}/mollie_webhook",
        metadata: {
          de_order_id: order.id.to_s,
          de_event_id: event.id.to_s
        },
        api_key: event.organisation.mollie_api_key
      )

      order.update_attributes!(
        value: order.total.round(2),
        mollie_payment_id: payment.id
      )
      order.tickets.each do |ticket|
        ticket.update_attributes!(mollie_payment_id: payment.id)
      end

      { redirect_url: payment.checkout_url }.to_json
    end

    def self.amount_hash(total, currency)
      cents = (total.to_d * 100).round
      { value: format('%.2f', cents / 100.0), currency: currency }
    end

    def self.refund(record, on_error:, amount: nil, **)
      return if record.mollie_payment_id.blank?

      amount ||= record.try(:value)
      ::Mollie::Payment::Refund.create(
        payment_id: record.mollie_payment_id,
        amount: amount_hash(amount, record.currency),
        api_key: record.event.organisation.mollie_api_key
      )
    rescue StandardError => e
      on_error.call(e) if on_error
      true
    end
  end
end
