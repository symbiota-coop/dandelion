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
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "New order for #{event.name}"
    batch_message.body_html EmailHelper.html(:order, account: account, order: order, event: event)

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
    order = self
    event = Sentry.with_child_span(op: 'db.mongo.read', description: 'order.event') { order.event }
    account = Sentry.with_child_span(op: 'db.mongo.read', description: 'order.account') { order.account }
    ticket_count = Sentry.with_child_span(op: 'db.mongo.count', description: 'order.tickets.count') { tickets.count }
    event_session_count = Sentry.with_child_span(op: 'db.mongo.count', description: 'event.event_sessions.count') { event.event_sessions.count }

    Sentry.configure_scope do |scope|
      scope.set_context('send_tickets', {
                          order_id: id.to_s,
                          event_id: event&.id.to_s,
                          account_id: account&.id.to_s,
                          ticket_count: ticket_count,
                          event_session_count: event_session_count,
                          no_tickets_pdf: event.no_tickets_pdf,
                          evergreen: event.evergreen?,
                          signal_order_link: account&.phone.present?
                        })
    end

    mg_client = Sentry.with_child_span(op: 'mailgun.client', description: 'Mailgun::Client.new') do
      Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    end
    batch_message = Sentry.with_child_span(op: 'mailgun.batch', description: 'Mailgun::BatchMessage.new') do |span|
      mailgun_host = EmailHelper.mailgun_host(account.email, ENV['MAILGUN_TICKETS_HOST'])
      span&.set_data('mailgun.host', mailgun_host)
      Mailgun::BatchMessage.new(mg_client, mailgun_host)
    end

    header_image_url, from_email = Sentry.with_child_span(op: 'email.sender', description: 'order ticket sender info') do |span|
      result = sender_info
      span&.set_data('email.sender_has_header_image', result.first.present?)
      result
    end

    subject = Sentry.with_child_span(op: 'email.subject', description: 'order ticket subject') do |span|
      span&.set_data('ticket_count', ticket_count)
      ((event.recording? ? event.recording_email_title : event.ticket_email_title) || (event.recording? ? event.organisation.recording_email_title : event.organisation.ticket_email_title))
        .gsub('[ticket_or_tickets]', ticket_count == 1 ? 'Ticket' : 'Tickets')
        .gsub('[event_name]', event.name)
    end
    batch_message.subject(subject)

    batch_message.from from_email
    batch_message.reply_to(event.email || event.organisation.reply_to)

    tickets_table = Sentry.with_child_span(op: 'template.render', description: 'emails/_tickets_table') do |span|
      span&.set_data('ticket_count', ticket_count)
      EmailHelper.render(:_tickets_table, event: event, account: account)
    end
    body_html = Sentry.with_child_span(op: 'email.html', description: 'emails/tickets premailer') do |span|
      html = EmailHelper.html(:tickets, event: event, order: order, account: account, tickets_table: tickets_table, header_image_url: header_image_url)
      span&.set_data('email.html_bytes', html.bytesize)
      html
    end
    batch_message.body_html body_html

    unless event.no_tickets_pdf
      Sentry.with_child_span(op: 'email.attachment.pdf', description: 'order tickets pdf attachment') do |span|
        tickets_pdf_filename = "#{ticket_count == 1 ? 'ticket' : 'tickets'}-#{event.name.parameterize}-#{order.id}.pdf"
        span&.set_data('ticket_count', ticket_count)
        tickets_pdf_file = File.new(tickets_pdf_filename, 'w+')
        pdf = Sentry.with_child_span(op: 'pdf.render', description: 'order.tickets_pdf.render') do |render_span|
          rendered_pdf = order.tickets_pdf.render
          render_span&.set_data('pdf.bytes', rendered_pdf.bytesize)
          rendered_pdf
        end
        tickets_pdf_file.write pdf
        tickets_pdf_file.rewind
        batch_message.add_attachment tickets_pdf_file, tickets_pdf_filename
      end
    end

    ics_files = []
    unless event.evergreen?
      Sentry.with_child_span(op: 'email.attachment.ics', description: 'order calendar attachments') do |span|
        span&.set_data('event_session_count', event_session_count)
        if event.event_sessions.empty?
          cal = event.ical(order: order)
          ics_filename = "event-#{event.name.parameterize}-#{order.id}.ics"
          ics_file = File.new(ics_filename, 'w+')
          ics_file.write cal.to_ical
          ics_file.rewind
          batch_message.add_attachment ics_file, ics_filename
          ics_files << [ics_file, ics_filename]
        else
          event.event_sessions.each do |event_session|
            cal = event_session.ical(order: order)
            ics_filename = "event-session-#{event_session.name.parameterize}-#{order.id}.ics"
            ics_file = File.new(ics_filename, 'w+')
            ics_file.write cal.to_ical
            ics_file.rewind
            batch_message.add_attachment ics_file, ics_filename
            ics_files << [ics_file, ics_filename]
          end
        end
        span&.set_data('attachment.count', ics_files.length)
      end
    end

    Sentry.with_child_span(op: 'mailgun.recipient', description: 'add ticket recipient') do
      batch_message.add_recipient(:to, account.email, { 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    if ENV['MAILGUN_API_KEY']
      message_ids = Sentry.with_child_span(op: 'mailgun.finalize', description: 'send ticket email') do |span|
        span&.set_data('attachment.count', ics_files.length + (event.no_tickets_pdf ? 0 : 1))
        span&.set_data('ticket_count', ticket_count)
        batch_message.finalize
      end
      Sentry.with_child_span(op: 'db.mongo.write', description: 'order.set message_ids') do
        set(message_ids: message_ids)
      end
    end

    Sentry.with_child_span(op: 'file.cleanup', description: 'ticket email attachments') do |span|
      span&.set_data('attachment.count', ics_files.length + (event.no_tickets_pdf ? 0 : 1))
      unless event.no_tickets_pdf
        tickets_pdf_file.close
        File.delete(tickets_pdf_filename)
      end
      ics_files.each do |f, fn|
        f.close
        File.delete(fn)
      end
    end

    # Send Signal message if account has phone number
    Sentry.with_child_span(op: 'signal.send', description: 'send order link') do |span|
      span&.set_data('signal.configured', signal_configured?)
      send_signal_order_link
    end if account&.phone.present?
  end

  def send_signal_order_link
    return unless signal_configured?
    return unless account&.phone.present?

    order_url = "#{ENV['BASE_URI']}/orders/#{id}"
    wd = event.when_details(account.try(:time_zone))
    when_text = wd ? ", #{wd.split(' (UTC')[0]}" : ''
    message = "Thanks for booking onto #{event.name}#{when_text}!\n\nView your order confirmation at #{order_url}"

    send_signal_message(account.phone, message)
  end

  def notify_of_failed_purchase(error, provider: 'Stripe')
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    order = self
    event = order.event
    account = order.account
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "#{provider} error on #{event.name}"
    batch_message.body_html EmailHelper.html(:purchase_failed, account: account, event: event, error: error, provider: provider)

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
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Refund failed: #{account.name} in #{event.name}"
    provider = order.payment_intent ? 'Stripe' : 'GoCardless'
    batch_message.body_html EmailHelper.html(:refund_failed_order, account: account, event: event, error: error, provider: provider)

    (event.contacts + Account.and(admin: true)).uniq.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
end
