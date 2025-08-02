module TicketNotifications
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_ticket
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

    content = ERB.new(File.read(Padrino.root('app/views/emails/tickets.erb'))).result(binding)
    batch_message.subject(event.ticket_email_title || "Ticket to #{event.name}")

    if event.organisation.send_ticket_emails_from_organisation && event.organisation.image
      header_image_url = event.organisation.image.thumb('1920x1920').url
      batch_message.from "#{event.organisation.name} <#{ENV['TICKETS_EMAIL']}>"
    else
      header_image_url = "#{ENV['BASE_URI']}/images/black-on-transparent-sq.png"
      batch_message.from ENV['TICKETS_EMAIL_FULL']
    end
    batch_message.reply_to(event.email || event.organisation.reply_to)

    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    unless event.no_tickets_pdf
      tickets_pdf_filename = "dandelion-#{event.name.parameterize}-#{order.id}.pdf"
      tickets_pdf_file = File.new(tickets_pdf_filename, 'w+')
      tickets_pdf_file.write order.tickets_pdf.render
      tickets_pdf_file.rewind
      batch_message.add_attachment tickets_pdf_file, tickets_pdf_filename
    end

    if event.event_sessions.empty?
      cal = event.ical(order: order)
      ics_filename = "dandelion-#{event.name.parameterize}-#{order.id}.ics"
      ics_file = File.new(ics_filename, 'w+')
      ics_file.write cal.to_ical
      ics_file.rewind
      batch_message.add_attachment ics_file, ics_filename
    else
      event.event_sessions.each do |event_session|
        cal = event_session.ical(order: order)
        ics_filename = "dandelion-#{event_session.name.parameterize}-#{order.id}.ics"
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

    batch_message.finalize if ENV['MAILGUN_API_KEY']

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
    content = ERB.new(File.read(Padrino.root('app/views/emails/refund_failed_ticket.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Refund failed: #{account.name} in #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    (event.event_facilitators + Account.and(admin: true)).uniq.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_resale_notification(previous_account)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    ticket = self
    order = ticket.order
    event = order.event
    account = order.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/ticket_resale.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Ticket resale: #{account.name} in #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    event.event_facilitators.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_email_update_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    ticket = self
    order = ticket.order
    event = order.event
    account = order.account

    return unless account

    content = ERB.new(File.read(Padrino.root('app/views/emails/ticket_email_update.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Ticket email update: #{account.name} in #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    event.event_facilitators.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
end
