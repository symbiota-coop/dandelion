class EventPaymentMethod
  module Paypal
    def self.call(order:, event:, **)
      paypal_order = client_for(event.organisation).create_order(
        amount: order.total,
        currency: order.currency,
        description: order.description,
        return_url: "#{ENV['BASE_URI']}/e/#{event.slug}?success=true&order_id=#{order.public_id}",
        cancel_url: "#{ENV['BASE_URI']}/e/#{event.slug}?cancelled=true",
        custom_id: order.id.to_s,
        brand_name: event.organisation.name,
        request_id: "dandelion-order-#{order.id}"
      )
      approve_url = ::Paypal.approve_url(paypal_order)
      raise ::Paypal::RequestError.new('PayPal did not return an approval URL', status: 502) if approve_url.blank?

      persist_order_id(order, paypal_order['id'])

      { redirect_url: approve_url }.to_json
    end

    def self.complete_if_paid(order)
      return if order.paypal_order_id.blank?

      organisation = order.event.organisation
      client = client_for(organisation)
      paypal_order = client.get_order(order.paypal_order_id)

      if ::Paypal.approved?(paypal_order) && !::Paypal.completed?(paypal_order)
        paypal_order = begin
          client.capture_order(order.paypal_order_id, request_id: "dandelion-capture-#{order.id}")
        rescue ::Paypal::RequestError => e
          raise if [401, 403].include?(e.status.to_i)

          client.get_order(order.paypal_order_id)
        end
      end

      return unless ::Paypal.completed?(paypal_order)

      order.persist_paypal_capture_id(::Paypal.capture_id(paypal_order))
      order.complete_or_restore(error_context: { paypal_order_id: order.paypal_order_id })
    end

    def self.refund(record, on_error:, amount: nil, **)
      return if record.paypal_capture_id.blank?

      amount ||= record.try(:value)
      client_for(record.event.organisation).refund_capture(
        record.paypal_capture_id,
        amount: amount,
        currency: record.currency
      )
    rescue StandardError => e
      on_error.call(e) if on_error
      true
    end

    def self.client_for(organisation)
      ::Paypal.new(
        client_id: organisation.paypal_client_id,
        secret: organisation.paypal_secret,
        sandbox: organisation.paypal_sandbox? || Padrino.env != :production
      )
    end

    def self.order_id_from_webhook(payload)
      resource = payload['resource'] || {}
      case payload['event_type']
      when 'CHECKOUT.ORDER.APPROVED', 'CHECKOUT.ORDER.COMPLETED'
        resource['id']
      when 'PAYMENT.CAPTURE.COMPLETED'
        resource.dig('supplementary_data', 'related_ids', 'order_id')
      end
    end

    def self.persist_order_id(order, paypal_order_id)
      order.update_attributes!(
        value: order.total.round(2),
        paypal_order_id: paypal_order_id
      )
      order.tickets.each do |ticket|
        ticket.update_attributes!(paypal_order_id: paypal_order_id)
      end
    end
  end
end
