class EventPaymentMethod
  module GoCardlessInstalments
    def self.call(order:, event:, **)
      organisation = event.organisation
      client = GoCardlessPro::Client.new(access_token: organisation.gocardless_access_token)
      instalment_count = organisation.gocardless_instalment_count || 3
      amount_demanded = order.total.round(2)

      billing_request = client.billing_requests.create(
        params: {
          mandate_request: {
            currency: order.currency
          },
          metadata: {
            de_order_id: order.id.to_s,
            de_event_id: event.id.to_s
          }
        }
      )

      order.update_attributes!(
        value: amount_demanded,
        amount_demanded: amount_demanded,
        amount_paid: 0,
        instalment_count: instalment_count,
        gocardless_billing_request_id: billing_request.id
      )

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

    def self.split_amounts_in_pence(total_major, count)
      total = (BigDecimal(total_major.to_s) * 100).round.to_i
      base = total / count
      amounts = Array.new(count, base)
      amounts[-1] += total - amounts.sum
      amounts
    end

    def self.create_schedule_for_order!(order)
      return if order.gocardless_instalment_schedule_id.present?
      return unless order.gocardless_billing_request_id.present?

      organisation = order.event.organisation
      client = GoCardlessPro::Client.new(access_token: organisation.gocardless_access_token)
      billing_request = client.billing_requests.get(order.gocardless_billing_request_id)
      mandate_id = billing_request.links.mandate_request_mandate
      if mandate_id.blank? && billing_request.mandate_request.is_a?(Hash)
        mandate_id = billing_request.mandate_request.dig('links', 'mandate')
      end
      return unless mandate_id

      mandate = client.mandates.get(mandate_id)
      start_date = mandate.next_possible_charge_date || (Date.today + 3).iso8601

      count = order.instalment_count || organisation.gocardless_instalment_count || 3
      amounts = split_amounts_in_pence(order.amount_demanded || order.value || order.total, count)

      schedule = client.instalment_schedules.create_with_schedule(
        params: {
          name: order.description.truncate(100),
          currency: order.currency,
          total_amount: amounts.sum,
          retry_if_possible: true,
          metadata: {
            de_order_id: order.id.to_s,
            de_event_id: order.event_id.to_s
          },
          instalments: {
            start_date: start_date,
            interval_unit: 'monthly',
            interval: 1,
            amounts: amounts
          },
          links: { mandate: mandate_id }
        }
      )

      order.set(
        gocardless_mandate_id: mandate_id,
        gocardless_instalment_schedule_id: schedule.id
      )
      schedule
    end
  end
end
