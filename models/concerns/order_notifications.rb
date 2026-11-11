module OrderNotifications
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_notification
    handle_asynchronously :send_tickets
    handle_asynchronously :send_signal_order_link

    before_destroy :queue_rsvp_cancelled_notification
  end

  class_methods do
    def send_rsvp_cancelled_email(event_id, recipients)
      event = Event.find(event_id)
      return unless event&.organisation
      return if recipients.blank?

      header_image_url, from_email = Order.new(event: event).sender_info
      Mailer.deliver(
        :rsvp_cancelled,
        to: recipients.map do |recipient|
          vars = { 'firstname' => recipient['firstname'] || 'there' }
          vars['token'] = recipient['token'] if recipient['token']
          vars['id'] = recipient['id'] if recipient['id']
          [recipient['email'], vars]
        end,
        subject: "Your RSVP to #{event.name} has been cancelled",
        locals: { event: event, header_image_url: header_image_url },
        stream: :tickets,
        microsoft_workaround: true,
        from: from_email,
        reply_to: event.email || event.organisation.reply_to
      )
    end
  end

  def send_notification
    order = self
    event = order.event
    Mailer.deliver(:order, to: event.event_facilitators, subject: "New order for #{event.name}", locals: { account: order.account, order: order, event: event })
  end

  def send_tickets
    order = self
    event = order.event
    header_image_url, from_email = sender_info

    account = order.account

    attachments = []
    attachments << ["#{tickets.count == 1 ? 'ticket' : 'tickets'}-#{event.name.parameterize}-#{order.id}.pdf", order.tickets_pdf.render] unless event.no_tickets_pdf
    attachments << ["donation-receipt-#{order.id}.pdf", order.donation_receipt_pdf.render] if donation_receipt?
    unless event.evergreen?
      if event.event_sessions.empty?
        attachments << ["event-#{event.name.parameterize}-#{order.id}.ics", event.ical(order: order).to_ical]
      else
        event.event_sessions.each do |event_session|
          attachments << ["event-session-#{event_session.name.parameterize}-#{order.id}.ics", event_session.ical(order: order).to_ical]
        end
      end
    end

    message_ids = Mailer.deliver(
      :tickets,
      to: [account.email, { 'token' => account.link_token_for_email, 'id' => account.id.to_s }],
      subject: EmailFields.replace_magic_tags(
        (event.recording? ? event.recording_email_title : event.ticket_email_title) || (event.recording? ? event.organisation.recording_email_title : event.organisation.ticket_email_title),
        event: event,
        account: account,
        orders: [order],
        plain_text: true
      ),
      locals: { event: event, order: order, account: account, tickets_table: EmailHelper.render(:_tickets_table, event: event, account: account), header_image_url: header_image_url },
      stream: :tickets,
      microsoft_workaround: true,
      from: from_email,
      reply_to: event.email || event.organisation.reply_to,
      attachments: attachments,
      send_when: :configured
    )
    set(message_ids: message_ids) if message_ids

    # Send Signal message if account has phone number, as its own job: Signal can take seconds to send
    send_signal_order_link if account&.phone.present?
  end

  def queue_rsvp_cancelled_notification
    return unless payment_completed
    return unless value.nil? || value.zero?
    return unless event && !event.flagged_for_destroy?

    recipients = rsvp_cancelled_recipients
    return if recipients.empty?

    self.class.delay.send_rsvp_cancelled_email(event.id.to_s, recipients)
  end

  def rsvp_cancelled_recipients
    recipients = []
    if account&.email.present?
      recipients << {
        'email' => account.email,
        'firstname' => account.greeting_name,
        'token' => account.link_token_for_email,
        'id' => account.id.to_s
      }
    end

    if event&.send_ticketholder_confirmation
      tickets.each do |ticket|
        email = ticket.email
        next if email.blank?
        next if recipients.any? { |recipient| recipient['email'] == email }

        recipients << {
          'email' => email,
          'firstname' => ticket.firstname || 'there'
        }
      end
    end

    recipients
  end

  def send_signal_order_link
    return unless signal_configured?
    return unless account&.phone.present?

    order_url = "#{ENV['BASE_URI']}/orders/#{public_id}"
    wd = event.when_details(account.try(:time_zone))
    when_text = wd ? ", #{wd.split(' (UTC')[0]}" : ''
    message = "Thanks for booking onto #{event.name}#{when_text}!\n\nView your order confirmation at #{order_url}"

    send_signal_message(account.phone, message)
  end

  def notify_of_failed_purchase(error, provider: nil, help: nil)
    event = self.event
    Mailer.deliver(
      :purchase_failed,
      to: (event.organisation.admins_receiving_feedback + Account.and(admin: true)).uniq,
      subject: "#{provider || 'Payment'} error on #{event.name}",
      locals: { account: account, event: event, error: error, provider: provider, help: help }
    )
  end

  def notify_of_failed_refund(error)
    event = self.event
    Mailer.deliver(
      :refund_failed_order,
      to: ((refund_contacts || event.contacts) + Account.and(admin: true)).uniq,
      subject: "Refund failed: #{account.name} in #{event.name}",
      locals: { account: account, event: event, error: error, provider: refund_provider }
    )
  end
end
