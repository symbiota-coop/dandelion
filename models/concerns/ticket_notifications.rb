module TicketNotifications
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_ticket
  end

  def sender_info
    if event.organisation.send_ticket_emails_from_organisation && event.organisation.image
      [event.organisation.image.thumb('1920x1920').url, "#{event.organisation.name} <#{ENV['TICKETS_EMAIL']}>"]
    else
      [nil, ENV['TICKETS_EMAIL_FULL']]
    end
  end

  def send_ticket
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_TICKETS_HOST'])

    ticket = self
    order = event.orders.new
    account = if email
                Account.new(name: ticket.name)
              else
                ticket.account
              end
    order.tickets = [ticket]
    order.account = account

    batch_message.subject(event.ticket_email_title || "Ticket to #{event.name}")

    header_image_url, from_email = sender_info

    batch_message.from from_email
    batch_message.reply_to(event.email || event.organisation.reply_to)

    tickets_table = EmailHelper.render(:_tickets_table, event: event, account: account)
    batch_message.body_html EmailHelper.html(:tickets, event: event, order: order, account: account, tickets_table: tickets_table, header_image_url: header_image_url)

    unless event.no_tickets_pdf
      tickets_pdf_filename = "ticket-#{event.name.parameterize}-#{order.id}.pdf"
      tickets_pdf_file = File.new(tickets_pdf_filename, 'w+')
      tickets_pdf_file.write order.tickets_pdf.render
      tickets_pdf_file.rewind
      batch_message.add_attachment tickets_pdf_file, tickets_pdf_filename
    end

    if event.event_sessions.empty?
      cal = event.ical(order: order)
      ics_filename = "event-#{event.name.parameterize}-#{order.id}.ics"
      ics_file = File.new(ics_filename, 'w+')
      ics_file.write cal.to_ical
      ics_file.rewind
      batch_message.add_attachment ics_file, ics_filename
    else
      event.event_sessions.each do |event_session|
        cal = event_session.ical(order: order)
        ics_filename = "event-session-#{event_session.name.parameterize}-#{order.id}.ics"
        ics_file = File.new(ics_filename, 'w+')
        ics_file.write cal.to_ical
        ics_file.rewind
        batch_message.add_attachment ics_file, ics_filename
      end
    end

    if email
      batch_message.add_recipient(:to, email)
    else
      [account].each do |account|
        batch_message.add_recipient(:to, account.email, { 'token' => account.sign_in_token, 'id' => account.id.to_s })
      end
    end

    batch_message.finalize if Padrino.env == :production

    unless event.no_tickets_pdf
      tickets_pdf_file.close
      File.delete(tickets_pdf_filename)
    end
    ics_file.close
    File.delete(ics_filename)
  end

  def notify_of_failed_refund(error)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    ticket = self
    order = ticket.order
    event = order.event
    account = order.account
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Refund failed: #{account.name} in #{event.name}"
    batch_message.body_html EmailHelper.html(:refund_failed_ticket, account: account, event: event, error: error)

    (event.contacts + Account.and(admin: true)).uniq.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end

  def send_resale_notification_to_previous_ticketholder(previous_account)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    ticket = self
    order = ticket.order
    event = order.event
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Your ticket to #{event.name} was resold"
    batch_message.body_html EmailHelper.html(:ticket_resale_previous_ticketholder, event: event)

    [previous_account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end

  def send_resale_notification_to_organiser(previous_account)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    ticket = self
    order = ticket.order
    event = order.event
    account = order.account
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Ticket resale: #{account.name} in #{event.name}"
    batch_message.body_html EmailHelper.html(:ticket_resale, account: account, event: event, previous_account: previous_account)

    event.event_facilitators.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end

  def send_email_update_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    ticket = self
    order = ticket.order
    event = order.event
    account = order.account

    return unless account && ticket.email

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Ticket email update: #{account.name} in #{event.name}"
    batch_message.body_html EmailHelper.html(:ticket_email_update, account: account, event: event, ticket: ticket)

    event.event_facilitators.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
end
