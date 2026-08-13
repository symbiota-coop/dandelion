class EventPaymentMethod
  module GoCardless
    def self.call(order:, event:, **)
      client = GoCardlessPro::Client.new(access_token: event.organisation.gocardless_access_token)
      billing_request = client.billing_requests.create(
        params: {
          payment_request: {
            description: order.description.truncate(200),
            amount: (order.total * 100).round,
            currency: order.currency
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

      { gocardless_billing_request_flow: billing_request_flow }.to_json
    end
  end
end
