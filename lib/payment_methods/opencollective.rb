class PaymentMethod
  module OpenCollective
    def self.call(order:, **)
      oc_secret = "dandelion:#{Array.new(5) { [*'a'..'z', *'0'..'9'].sample }.join}"
      order.update_attributes!(
        value: order.total.round(2),
        oc_secret: oc_secret
      )
      {
        oc_secret: order.oc_secret,
        value: order.value,
        order_id: order.id.to_s,
        order_expiry: (order.created_at + 1.hour).to_datetime.strftime('%Q')
      }.to_json
    end
  end
end
