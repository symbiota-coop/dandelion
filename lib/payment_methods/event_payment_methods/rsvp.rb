class EventPaymentMethod
  module Rsvp
    def self.call(order:, **)
      order.complete_or_restore
      { order_id: order.id.to_s }.to_json
    end
  end
end
