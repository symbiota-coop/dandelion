module EventNotifications
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_reminders
    handle_asynchronously :send_star_reminders
    handle_asynchronously :send_feedback_requests
    handle_asynchronously :send_first_event_email
  end

  def send_first_event_email
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/first_event.erb'))).result(binding)
    batch_message.from ENV['FOUNDER_EMAIL_FULL']
    batch_message.reply_to ENV['FOUNDER_EMAIL']
    batch_message.subject 'Congratulations on listing your first event on Dandelion!'
    batch_message.body_text content

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there' })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    account.update_attribute(:sent_first_event_email, Time.now)
  end

  def send_destroy_notification(destroyed_by)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/event_destroyed.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "#{destroyed_by.name} deleted the event #{event.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    accounts_receiving_feedback.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_reminders(account_id)
    return unless organisation
    return if prevent_reminders

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/reminder.erb'))).result(binding)
    batch_message.from ENV['REMINDERS_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject(
      (event.reminder_email_title || event.organisation.reminder_email_title)
      .gsub('[event_name]', event.name)
    )
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    (account_id == :all ? attendees.and(:unsubscribed.ne => true).and(:unsubscribed_reminders.ne => true) : attendees.and(:unsubscribed.ne => true).and(:unsubscribed_reminders.ne => true).and(id: account_id)).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_star_reminders(account_id)
    return unless organisation

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/reminder_starred.erb'))).result(binding)
    batch_message.from ENV['REMINDERS_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject "#{event.name} is next week"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    (account_id == :all ? starrers.and(:unsubscribed.ne => true).and(:unsubscribed_reminders.ne => true) : starrers.and(:unsubscribed.ne => true).and(:unsubscribed_reminders.ne => true).and(id: account_id)).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_feedback_requests(account_id)
    return if feedback_questions.nil?
    return unless organisation

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    event = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/feedback.erb'))).result(binding)
    batch_message.from ENV['FEEDBACK_EMAIL_FULL']
    batch_message.reply_to(event.email || event.organisation.try(:reply_to))
    batch_message.subject(
      (event.feedback_email_title || event.organisation.feedback_email_title)
      .gsub('[event_name]', event.name)
    )
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    (account_id == :all ? attendees.and(:unsubscribed.ne => true).and(:unsubscribed_feedback.ne => true) : attendees.and(:unsubscribed.ne => true).and(:unsubscribed_feedback.ne => true).and(id: account_id)).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
end
