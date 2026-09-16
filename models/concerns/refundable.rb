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

    notify_of_refund(amount: amount || try(:value))
  end

  def notify_of_refund(amount:)
    return unless amount && amount > 0

    event = self.event
    account = self.account
    return unless event&.organisation && account&.email.present?

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, EmailHelper.mailgun_host(account.email, ENV['MAILGUN_TICKETS_HOST']))

    header_image_url, from_email = sender_info
    formatted_amount = Money.new(amount * 100, currency).format(no_cents_if_whole: true)

    batch_message.subject "Your refund for #{event.name}"
    batch_message.from from_email
    batch_message.reply_to(event.email || event.organisation.reply_to)
    batch_message.body_html EmailHelper.html(:refund, event: event, amount: formatted_amount, provider: refund_provider, header_image_url: header_image_url)
    batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token_for_email, 'id' => account.id.to_s })
    batch_message.finalize if Padrino.env == :production
  end
end
