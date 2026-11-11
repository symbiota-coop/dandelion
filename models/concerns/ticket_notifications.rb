module TicketNotifications
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_ticket
  end

  def send_ticket
    ticket = self
    order = event.orders.new
    account = if email
                Account.new(name: ticket.name)
              else
                ticket.account
              end
    order.tickets = [ticket]
    order.account = account

    header_image_url, from_email = sender_info

    attachments = []
    attachments << ["ticket-#{event.name.parameterize}-#{order.id}.pdf", order.tickets_pdf.render] unless event.no_tickets_pdf
    unless event.evergreen?
      if event.event_sessions.empty?
        attachments << ["event-#{event.name.parameterize}-#{order.id}.ics", event.ical(order: order).to_ical]
      else
        event.event_sessions.each do |event_session|
          attachments << ["event-session-#{event_session.name.parameterize}-#{order.id}.ics", event_session.ical(order: order).to_ical]
        end
      end
    end

    Mailer.deliver(
      :tickets,
      to: email || [account.email, { 'token' => account.link_token_for_email, 'id' => account.id.to_s }],
      subject: EmailFields.replace_magic_tags(
        event.ticket_email_title || "Ticket to #{event.name}",
        event: event,
        account: account,
        orders: [order],
        plain_text: true
      ),
      locals: { event: event, order: order, ticket: ticket, account: account, tickets_table: EmailHelper.render(:_tickets_table, event: event, account: account), header_image_url: header_image_url },
      stream: :tickets,
      microsoft_workaround: true,
      from: from_email,
      reply_to: event.email || event.organisation.reply_to,
      attachments: attachments
    )
  end

  def notify_of_failed_refund(error)
    event = self.event
    Mailer.deliver(
      :refund_failed_ticket,
      to: (event.contacts + Account.and(admin: true)).uniq,
      subject: "Refund failed: #{account.name} in #{event.name}",
      locals: { account: account, event: event, error: error, provider: refund_provider }
    )
  end

  def send_resale_notification_to_previous_ticketholder(previous_account, requires_manual_refund: false, gocardless_instalment: false)
    Mailer.deliver(
      :ticket_resale_previous_ticketholder,
      to: previous_account,
      subject: "Your ticket to #{event.name} was resold",
      locals: { event: event, requires_manual_refund: requires_manual_refund, gocardless_instalment: gocardless_instalment }
    )
  end

  def send_resale_notification_to_organiser(previous_account, requires_manual_refund: false, gocardless_instalment: false, refund_amount: nil, order_total: nil, currency: nil)
    event = self.event
    Mailer.deliver(
      :ticket_resale,
      to: requires_manual_refund ? (event.contacts + Account.and(admin: true)).uniq : event.event_facilitators,
      subject: if requires_manual_refund
                 "Ticket resale (refund required): #{account.name} in #{event.name}"
               else
                 "Ticket resale: #{account.name} in #{event.name}"
               end,
      locals: {
        account: account,
        event: event,
        previous_account: previous_account,
        requires_manual_refund: requires_manual_refund,
        gocardless_instalment: gocardless_instalment,
        refund_amount: refund_amount,
        order_total: order_total,
        currency: currency
      }
    )
  end

  def send_email_update_notification
    return unless account && email

    Mailer.deliver(
      :ticket_email_update,
      to: event.event_facilitators,
      subject: "Ticket email update: #{account.name} in #{event.name}",
      locals: { account: account, event: event, ticket: self }
    )
  end
end
