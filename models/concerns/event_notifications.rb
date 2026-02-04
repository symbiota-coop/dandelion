module EventNotifications
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_reminders
    handle_asynchronously :send_star_reminders
    handle_asynchronously :send_feedback_requests
    handle_asynchronously :send_waitlist_tickets_available
  end

  def send_destroy_notification(destroyed_by)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "#{destroyed_by.name} deleted the event #{event.name}"
    batch_message.body_html EmailHelper.html(:event_destroyed, destroyed_by: destroyed_by, event: event)

    accounts_receiving_feedback.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end

  def send_reminders(account_id)
    return unless organisation
    return if prevent_reminders

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self

    batch_message.from ENV['REMINDERS_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject(
      (event.reminder_email_title || event.organisation.reminder_email_title)
      .gsub('[event_name]', event.name)
    )

    tickets_table = EmailHelper.render(:_tickets_table, event: event)
    batch_message.body_html EmailHelper.html(:reminder, event: event, tickets_table: tickets_table)

    (account_id == :all ? attendees.and(unsubscribed: false).and(unsubscribed_reminders: false) : attendees.and(unsubscribed: false).and(unsubscribed_reminders: false).and(id: account_id)).each do |account|
      when_parts = event.when_details(account.try(:time_zone), with_zone: true).split(', ')
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s, 'when_parts_0' => when_parts[0], 'when_parts_1' => when_parts[1..].join(', ') })
    end

    batch_message.finalize if Padrino.env == :production
    set(sent_reminders_at: Time.now) if account_id == :all
  end

  def send_star_reminders(account_id)
    return unless organisation

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self

    batch_message.from ENV['REMINDERS_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject "#{event.name} is next week"

    tickets_table = EmailHelper.render(:_tickets_table, event: event)
    batch_message.body_html EmailHelper.html(:reminder_starred, event: event, tickets_table: tickets_table)

    (account_id == :all ? starrers.and(unsubscribed: false).and(unsubscribed_reminders: false) : starrers.and(unsubscribed: false).and(unsubscribed_reminders: false).and(id: account_id)).each do |account|
      when_parts = event.when_details(account.try(:time_zone), with_zone: true).split(', ')
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s, 'when_parts_0' => when_parts[0], 'when_parts_1' => when_parts[1..].join(', ') })
    end

    batch_message.finalize if Padrino.env == :production
    set(sent_star_reminders_at: Time.now) if account_id == :all
  end

  def send_feedback_requests(account_id)
    return if feedback_questions.nil?
    return unless organisation
    return if sent_feedback_requests_at && account_id == :all

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    batch_message.from ENV['FEEDBACK_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject(
      (event.feedback_email_title || event.organisation.feedback_email_title)
      .gsub('[event_name]', event.name)
    )
    batch_message.body_html EmailHelper.html(:feedback, event: event)

    (account_id == :all ? attendees.and(unsubscribed: false).and(unsubscribed_feedback: false) : attendees.and(unsubscribed: false).and(unsubscribed_feedback: false).and(id: account_id)).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
    set(sent_feedback_requests_at: Time.now) if account_id == :all
  end

  def send_waitlist_tickets_available
    return unless organisation
    return unless tickets_available?
    return if waitships.empty?

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject "Tickets now available for #{event.name}"
    batch_message.body_html EmailHelper.html(:waitlist_tickets_available, event: event)

    waiters.and(unsubscribed: false).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
end
