module OrderNotifications
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_notification
    handle_asynchronously :send_tickets

    before_destroy :queue_rsvp_cancelled_notification
  end

  class_methods do
    def send_rsvp_cancelled_email(event_id, recipients)
      event = Event.find(event_id)
      return unless event&.organisation
      return if recipients.blank?

      mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
      first_email = recipients.first['email']
      batch_message = Mailgun::BatchMessage.new(mg_client, EmailHelper.mailgun_host(first_email, ENV['MAILGUN_TICKETS_HOST']))

      header_image_url, from_email = Order.new(event: event).sender_info
      batch_message.subject "Your RSVP to #{event.name} has been cancelled"
      batch_message.from from_email
      batch_message.reply_to(event.email || event.organisation.reply_to)
      batch_message.body_html EmailHelper.html(:rsvp_cancelled, event: event, header_image_url: header_image_url)

      recipients.each do |recipient|
        vars = { 'firstname' => recipient['firstname'] || 'there' }
        vars['token'] = recipient['token'] if recipient['token']
        vars['id'] = recipient['id'] if recipient['id']
        batch_message.add_recipient(:to, recipient['email'], vars)
      end

      batch_message.finalize if Padrino.env == :production
    end
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
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token_for_email, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end

  def sender_info
    if event.organisation.send_ticket_emails_from_organisation && event.organisation.image
      [event.organisation.image.url, "#{event.organisation.name} <#{ENV['TICKETS_EMAIL']}>"]
    else
      [nil, ENV['TICKETS_EMAIL_FULL']]
    end
  end

  def send_tickets
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, EmailHelper.mailgun_host(account.email, ENV['MAILGUN_TICKETS_HOST']))

    order = self
    event = order.event
    header_image_url, from_email = sender_info

    account = order.account

    batch_message.subject(
      EmailFields.replace_magic_tags(
        (event.recording? ? event.recording_email_title : event.ticket_email_title) || (event.recording? ? event.organisation.recording_email_title : event.organisation.ticket_email_title),
        event: event,
        account: account,
        orders: [order],
        plain_text: true
      )
    )

    batch_message.from from_email
    batch_message.reply_to(event.email || event.organisation.reply_to)

    tickets_table = EmailHelper.render(:_tickets_table, event: event, account: account)
    batch_message.body_html EmailHelper.html(:tickets, event: event, order: order, account: account, tickets_table: tickets_table, header_image_url: header_image_url)

    tickets_pdf_file = nil
    tickets_pdf_filename = nil
    unless event.no_tickets_pdf
      tickets_pdf_filename = "#{tickets.count == 1 ? 'ticket' : 'tickets'}-#{event.name.parameterize}-#{order.id}.pdf"
      tickets_pdf_file = File.new(tickets_pdf_filename, 'w+')
      tickets_pdf_file.write order.tickets_pdf.render
      tickets_pdf_file.rewind
      batch_message.add_attachment tickets_pdf_file, tickets_pdf_filename
    end

    ics_files = []
    unless event.evergreen?
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
    end

    batch_message.add_recipient(:to, account.email, { 'token' => account.sign_in_token_for_email, 'id' => account.id.to_s })

    if ENV['MAILGUN_API_KEY']
      message_ids = batch_message.finalize
      set(message_ids: message_ids)
    end

    if tickets_pdf_file && tickets_pdf_filename
      tickets_pdf_file.close
      File.delete(tickets_pdf_filename)
    end
    ics_files.each do |f, fn|
      f.close
      File.delete(fn)
    end

    # Send Signal message if account has phone number
    Sentry.with_child_span(op: 'http.client', description: 'POST Signal /v2/send') do |span|
      span&.set_data('http.request.method', 'POST')
      span&.set_data('url', "#{ENV['SIGNAL_API_URL']}/v2/send") if ENV['SIGNAL_API_URL'].present?
      span&.set_data('signal.configured', signal_configured?)
      send_signal_order_link
    end if account&.phone.present?
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
        'firstname' => account.firstname || 'there',
        'token' => account.sign_in_token_for_email,
        'id' => account.id.to_s
      }
    end

    if event&.send_ticketholder_confirmation
      tickets.each do |ticket|
        email = ticket.email.presence
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
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token_for_email, 'id' => account.id.to_s })
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
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token_for_email, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
end
