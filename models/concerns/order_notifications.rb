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

    batch_message.finalize if Padrino.env == :production
  end

  def sender_info
    if event.organisation.send_ticket_emails_from_organisation && event.organisation.image
      [event.organisation.image.thumb('1920x1920').url, "#{event.organisation.name} <#{ENV['TICKETS_EMAIL']}>"]
    else
      [nil, ENV['TICKETS_EMAIL_FULL']]
    end
  end

  def send_tickets
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_TICKETS_HOST'])

    order = self
    event = order.event
    header_image_url, from_email = sender_info

    account = order.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/tickets.erb'))).result(binding)
    batch_message.subject(
      ((event.recording? ? event.recording_email_title : event.ticket_email_title) || (event.recording? ? event.organisation.recording_email_title : event.organisation.ticket_email_title))
      .gsub('[ticket_or_tickets]', tickets.count == 1 ? 'Ticket' : 'Tickets')
      .gsub('[event_name]', event.name)
    )

    batch_message.from from_email
    batch_message.reply_to(event.email || event.organisation.reply_to)

    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    unless event.no_tickets_pdf
      tickets_pdf_filename = "#{tickets.count == 1 ? 'ticket' : 'tickets'}-#{event.name.parameterize}-#{order.id}.pdf"
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

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    if ENV['MAILGUN_API_KEY']
      message_ids = batch_message.finalize
      set(message_ids: message_ids)
    end

    unless event.no_tickets_pdf
      tickets_pdf_file.close
      File.delete(tickets_pdf_filename)
    end
    ics_file.close
    File.delete(ics_filename)

    # Send WhatsApp message if account has phone number
    send_whatsapp_order_link if account&.phone.present?
  end

  def send_whatsapp_order_link
    return unless whatsapp_configured?
    return unless account&.phone.present?

    phone_number = format_phone_number(account.phone)
    return unless phone_number

    template_header = 'Thanks for booking onto {{1}}!'
    truncated_event_name = truncate_event_name_for_whatsapp(event.name, template_header)

    components = [
      {
        type: 'header',
        parameters: [
          { type: 'text', text: truncated_event_name }
        ]
      },
      {
        type: 'button',
        sub_type: 'url',
        index: '0',
        parameters: [
          { type: 'text', text: id.to_s }
        ]
      }
    ]

    send_whatsapp_template(phone_number, ENV['WHATSAPP_TEMPLATE_NAME_ORDER'], components)
  end

  def notify_of_failed_purchase(error)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    order = self
    event = order.event
    account = order.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/purchase_failed.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Stripe error on #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    (event.organisation.admins_receiving_feedback + Account.and(admin: true)).uniq.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end

  def notify_of_failed_refund(error)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    order = self
    event = order.event
    account = order.account
    content = ERB.new(File.read(Padrino.root('app/views/emails/refund_failed_order.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Refund failed: #{account.name} in #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    (event.contacts + Account.and(admin: true)).uniq.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
end
