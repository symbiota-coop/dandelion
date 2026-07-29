class EventPaymentMethod
  module Rsvp
    def self.call(order:, **)
      order.payment_completed!
      order.send_tickets
      order.create_order_notification
      { order_id: order.id.to_s }.to_json
    end
  end
end
