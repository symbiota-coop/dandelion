class EventPaymentMethod
  module GoCardlessInstalment
    def self.call(order:, event:, **)
      client = GoCardlessPro::Client.new(access_token: event.organisation.gocardless_access_token)
      billing_request = client.billing_requests.create(
        params: {
          mandate_request: {
            description: order.description.truncate(200),
            currency: order.currency,
            scheme: { 'GBP' => 'bacs', 'EUR' => 'sepa_core' }[order.currency]
          }.compact
        }
      )

      # leave 2 lines so layout is same as instant bank pay
      #
      order.update_attributes!(
        value: order.total.round(2),
        gocardless_billing_request_id: billing_request.id
      )
      order.tickets.each do |ticket|
        ticket.update_attributes!(gocardless_billing_request_id: billing_request.id)
      end

      return_base = "#{ENV['BASE_URI']}/e/#{event.slug}?billing_request_id=#{billing_request.id}"
      billing_request_flow = client.billing_request_flows.create(
        params: {
          redirect_uri: URI::DEFAULT_PARSER.escape("#{return_base}&success=true"),
          exit_uri: URI::DEFAULT_PARSER.escape("#{return_base}&cancelled=true"),
          lock_currency: true,
          links: { billing_request: billing_request.id }
        }
      )

      { gocardless_billing_request_flow: billing_request_flow }.to_json
    end
  end
end
