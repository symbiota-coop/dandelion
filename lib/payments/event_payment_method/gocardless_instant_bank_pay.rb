class EventPaymentMethod
  module GoCardlessInstantBankPay
    def self.call(order:, event:, **)
      client = GoCardlessPro::Client.new(access_token: event.organisation.gocardless_access_token)
      billing_request = client.billing_requests.create(
        params: {
          payment_request: {
            description: order.description.truncate(200),
            currency: order.currency,
            amount: (order.total * 100).round
          }
        }
      )

      payment_request_id = billing_request.links.payment_request
      order.update_attributes!(
        value: order.total.round(2),
        gocardless_payment_request_id: payment_request_id
      )
      order.tickets.each do |ticket|
        ticket.update_attributes!(gocardless_payment_request_id: payment_request_id)
      end

      return_base = "#{ENV['BASE_URI']}/e/#{event.slug}?payment_request_id=#{payment_request_id}"
      billing_request_flow = client.billing_request_flows.create(
        params: {
          redirect_uri: URI::DEFAULT_PARSER.escape("#{return_base}&success=true"),
          exit_uri: URI::DEFAULT_PARSER.escape("#{return_base}&cancelled=true"),
          links: { billing_request: billing_request.id }
        }
      )

      { redirect_url: billing_request_flow.authorisation_url }.to_json
    end

    def self.refund(record, on_error:, amount: nil, **)
      payment_id = record.gocardless_payment_id
      return if payment_id.blank?

      amount ||= record.try(:value)

      client = GoCardlessPro::Client.new(access_token: record.event.organisation.gocardless_access_token)
      refund_amount = (amount * 100).to_i
      payment = client.payments.get(payment_id)

      client.refunds.create(
        params: {
          amount: refund_amount,
          total_amount_confirmation: payment.amount_refunded + refund_amount,
          links: {
            payment: payment_id
          }
        }
      )
    rescue StandardError => e
      on_error.call(e) if on_error
      true
    end
  end
end
