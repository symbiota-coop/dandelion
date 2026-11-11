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

    failed = false
    result = pm.refund.call(
      self,
      amount: amount,
      on_error: lambda { |error|
        failed = true
        notify_of_failed_refund(error)
      },
      **
    )
    return if failed || result.nil?

    # The refund has gone through, so an email that fails is reported rather than raised: raised, it would look as if
    # the refund had failed. A provider that can refund less than was asked for (Stripe, when some was refunded
    # already) returns the amount it refunded
    begin
      notify_of_refund(amount: result.is_a?(Numeric) ? result : amount || try(:value))
    rescue StandardError => e
      ErrorReporting.capture_exception(e, context: { model: self.class.name, id: id.to_s })
    end
  end

  # The header image and sender of the emails an order's or ticket's holder gets: tickets, refunds and cancelled RSVPs
  def sender_info
    if event.organisation.send_ticket_emails_from_organisation && event.organisation.image
      [event.organisation.image.url, "#{event.organisation.name} <#{ENV['TICKETS_EMAIL']}>"]
    else
      [nil, ENV['TICKETS_EMAIL_FULL']]
    end
  end

  def notify_of_refund(amount:)
    return unless amount && amount > 0

    event = self.event
    account = self.account
    return unless event&.organisation && account&.email.present?

    header_image_url, from_email = sender_info
    Mailer.deliver(
      :refund,
      to: account,
      subject: "Your refund for #{event.name}",
      locals: { event: event, amount: Money.new(amount * 100, currency).format(no_cents_if_whole: true), provider: refund_provider, header_image_url: header_image_url },
      stream: :tickets,
      microsoft_workaround: true,
      from: from_email,
      reply_to: event.email || event.organisation.reply_to
    )
  end
end
