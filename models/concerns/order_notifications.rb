module OrderNotifications
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_notification
    handle_asynchronously :send_tickets
  end

  def send_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    order = self
    event = order.event
    account = order.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/order.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "New order for #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    event.event_facilitators.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_tickets
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_TICKETS_HOST'])

    order = self
    event = order.event

    account = order.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/tickets.erb'))).result(binding)
    batch_message.subject(event.ticket_email_title || "#{tickets.count == 1 ? 'Ticket' : 'Tickets'} to #{event.name}")

    if event.organisation.send_ticket_emails_from_organisation && event.organisation.reply_to && event.organisation.image
      header_image_url = event.organisation.image.url
      batch_message.from event.organisation.reply_to
      batch_message.reply_to event.email
    else
      header_image_url = "#{ENV['BASE_URI']}/images/black-on-transparent-sq.png"
      batch_message.from ENV['TICKETS_EMAIL_FULL']
      batch_message.reply_to(event.email || event.organisation.reply_to)
    end

    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    unless event.no_tickets_pdf
      tickets_pdf_filename = "dandelion-#{event.name.parameterize}-#{order.id}.pdf"
      tickets_pdf_file = File.new(tickets_pdf_filename, 'w+')
      tickets_pdf_file.write order.tickets_pdf.render
      tickets_pdf_file.rewind
      batch_message.add_attachment tickets_pdf_file, tickets_pdf_filename
    end

    cal = event.ical(order: order)
    ics_filename = "dandelion-#{event.name.parameterize}-#{order.id}.ics"
    ics_file = File.new(ics_filename, 'w+')
    ics_file.write cal.to_ical
    ics_file.rewind
    batch_message.add_attachment ics_file, ics_filename

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    if ENV['MAILGUN_API_KEY']
      message_ids = batch_message.finalize
      update_attribute(:message_ids, message_ids)
    end

    unless event.no_tickets_pdf
      tickets_pdf_file.close
      File.delete(tickets_pdf_filename)
    end
    ics_file.close
    File.delete(ics_filename)
  end
end