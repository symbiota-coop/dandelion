module Refundable
  def payment_method
    EventPaymentMethod.for_record(self)
  end

  def refundable?
    pm = payment_method
    pm&.refund && pm.payment_id(self).present?
  end

  def refund_provider
    payment_method&.provider_name
  end

  def refund_payment(amount: nil, **)
    pm = payment_method or return

    pm.refund.call(
      self,
      amount: amount,
      on_error: ->(error) { notify_of_failed_refund(error) },
      **
    )
  end
end
