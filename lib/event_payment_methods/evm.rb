class EventPaymentMethod
  module Evm
    def self.call(order:, **)
      evm_secret = Array.new(4) { [*'1'..'9'].sample }.join
      order.update_attributes!(
        value: order.total.round(2),
        evm_secret: evm_secret
      )
      {
        evm_secret: order.evm_secret,
        value: order.evm_value,
        wei: (order.evm_value * 1e18.to_d).to_i,
        order_id: order.id.to_s,
        order_expiry: (order.created_at + 1.hour).to_datetime.strftime('%Q')
      }.to_json
    end
  end
end
