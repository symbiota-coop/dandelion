class EventPaymentMethod
  module Paypal
    # Reported, not raised, when PayPal captured a different amount or currency from the order's: the money was taken,
    # so the order is still completed, but someone should look into it
    AmountMismatch = Class.new(StandardError)

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

      report_amount_mismatch(order, paypal_order) unless order.payment_completed?
      order.persist_paypal_capture_id(::Paypal.capture_id(paypal_order))
      order.complete_or_restore(error_context: { paypal_order_id: order.paypal_order_id })
    end

    # Compares what PayPal captured with what the order was sent to PayPal for (Paypal.amount_hash of its total and
    # currency). PayPal gives amounts as strings ("23.33", or "100" in currencies without decimals), so they're compared
    # as decimals. The captures' amounts are used where PayPal gives them, else the purchase unit's; with neither,
    # there's nothing to compare
    def self.report_amount_mismatch(order, paypal_order)
      expected = ::Paypal.amount_hash(order.total, order.currency)
      actual = captured_amount(paypal_order)
      return unless actual
      return if actual[:currency_code] == expected[:currency_code] && actual[:value] == BigDecimal(expected[:value])

      actual_value = actual[:value].to_s('F')
      ErrorReporting.capture_exception(
        AmountMismatch.new("PayPal captured #{actual_value} #{actual[:currency_code]} for order #{order.id}, expected #{expected[:value]} #{expected[:currency_code]}"),
        context: {
          order_id: order.id.to_s,
          paypal_order_id: order.paypal_order_id,
          expected_amount: expected[:value],
          expected_currency: expected[:currency_code],
          actual_amount: actual_value,
          actual_currency: actual[:currency_code]
        }
      )
    end

    # The total of the PayPal order's completed captures, or its purchase unit's amount if they give none
    def self.captured_amount(paypal_order)
      purchase_unit = paypal_order.dig('purchase_units', 0) || {}
      captures = (purchase_unit.dig('payments', 'captures') || []).select { |capture| capture['status'] == 'COMPLETED' }
      amounts = captures.filter_map { |capture| capture['amount'] }
      amounts = [purchase_unit['amount']].compact if amounts.empty?
      amounts = amounts.select { |amount| amount['value'].present? }
      return if amounts.empty?

      { currency_code: amounts.map { |amount| amount['currency_code'] }.uniq.join(','), value: amounts.sum { |amount| BigDecimal(amount['value']) } }
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
