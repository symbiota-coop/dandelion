module EventNotifications
  extend ActiveSupport::Concern

  included do
    handle_asynchronously :send_reminders
    handle_asynchronously :send_star_reminders
    handle_asynchronously :send_feedback_requests
    handle_asynchronously :send_waitlist_tickets_available
    handle_asynchronously :send_ticket_type_waitlist_tickets_available
    handle_asynchronously :send_public_submission_notification
  end

  def send_public_submission_notification
    return unless organisation

    Mailer.deliver(:event_submission, to: organisation.admins, subject: "New event submission: #{name}", locals: { event: self, account: account })
  end

  def send_destroy_notification(destroyed_by)
    Mailer.deliver(:event_destroyed, to: accounts_receiving_feedback, subject: "#{destroyed_by.name} deleted the event #{name}", locals: { destroyed_by: destroyed_by, event: self })
  end

  def send_reminders(account_id)
    return if evergreen?
    return unless organisation
    return unless reminder_hours_before

    event = self

    reminder_subject = EmailFields.replace_magic_tags(
      event.reminder_email_title || event.organisation.reminder_email_title,
      event: event,
      recipient_variables: true,
      plain_text: true
    )

    tickets_table = EmailHelper.render(:_tickets_table, event: event)

    recipients_with_cancel = []
    recipients_without_cancel = []

    (account_id == :all ? attendees.and(unsubscribed: false).and(unsubscribed_reminders: false) : attendees.and(unsubscribed: false).and(unsubscribed_reminders: false).and(id: account_id)).each do |account|
      attendee_orders = event.orders.complete.and(account: account).to_a
      cancellable_order = attendee_orders.find { |order| order.value.nil? || order.value.zero? }
      cancellable_ticket = (event.tickets.complete.without_order.and(account: account).detect(&:cancellable?) unless cancellable_order)

      when_parts = event.when_details(account.try(:time_zone), with_zone: true).split(', ')
      recipient_vars = EmailFields.recipient_variables(
        event: event,
        account: account
      )
                                        .merge('when_parts_0' => when_parts[0],
                                               'when_parts_1' => when_parts[1..].join(', '))

      if cancellable_order || cancellable_ticket
        cancel_rsvp_path = cancellable_order ? "/orders/#{cancellable_order.id}" : "/tickets/#{cancellable_ticket.id}"
        cancel_rsvp_url = "#{ENV['BASE_URI']}#{cancel_rsvp_path}/confirm_cancel?link_token=#{recipient_vars['token']}"
        recipients_with_cancel << [account.email, recipient_vars.merge('cancel_rsvp_url' => cancel_rsvp_url)]
      else
        recipients_without_cancel << [account.email, recipient_vars]
      end
    end

    { true => recipients_with_cancel, false => recipients_without_cancel }.each do |include_cancel_rsvp, recipients|
      Mailer.deliver(
        :reminder,
        to: recipients,
        subject: reminder_subject,
        locals: { event: event, tickets_table: tickets_table, include_cancel_rsvp: include_cancel_rsvp },
        from: ENV['REMINDERS_EMAIL_FULL'],
        reply_to: event.email || event.organisation.try(:reply_to)
      )
    end
    set(sent_reminders_at: Time.now) if account_id == :all
  end

  def reminder_due_within?(window, from = Time.now)
    return false unless reminder_hours_before
    return false unless start_time
    return false if sent_reminders_at
    return false if start_time <= from

    reminder_time = start_time - reminder_hours_before.hours
    reminder_time <= from + window
  end

  def feedback_due_within?(window, from = Time.now)
    return false if evergreen?
    return false unless feedback_questions.present?
    return false unless organisation
    return false unless end_time
    return false if sent_feedback_requests_at

    feedback_time = end_time + (feedback_hours_after || 0).hours
    return false if from > feedback_time + window

    feedback_time <= from + window
  end

  def send_star_reminders(account_id)
    return if evergreen?
    return unless organisation

    event = self
    Mailer.deliver(
      :reminder_starred,
      to: (account_id == :all ? starrers.and(unsubscribed: false).and(unsubscribed_reminders: false) : starrers.and(unsubscribed: false).and(unsubscribed_reminders: false).and(id: account_id)).map do |account|
        when_parts = event.when_details(account.try(:time_zone), with_zone: true).split(', ')
        account.mail_recipient('when_parts_0' => when_parts[0], 'when_parts_1' => when_parts[1..].join(', '))
      end,
      subject: "#{event.name} is next week",
      locals: { event: event, tickets_table: EmailHelper.render(:_tickets_table, event: event) },
      from: ENV['REMINDERS_EMAIL_FULL'],
      reply_to: event.email || event.organisation.try(:reply_to)
    )
    set(sent_star_reminders_at: Time.now) if account_id == :all
  end

  def send_feedback_requests(account_id, force_all = false)
    log_prefix = "send_feedback_requests event=#{id} account_id=#{account_id.inspect} force_all=#{force_all}"
    if evergreen?
      puts "#{log_prefix}: skip evergreen"
      return
    end
    if feedback_questions.nil?
      puts "#{log_prefix}: skip feedback_questions nil"
      return
    end
    unless organisation
      puts "#{log_prefix}: skip no organisation"
      return
    end
    if sent_feedback_requests_at && account_id == :all && !force_all
      puts "#{log_prefix}: skip already sent at #{sent_feedback_requests_at}"
      return
    end

    event = self
    recipients = account_id == :all ? attendees.and(unsubscribed: false).and(unsubscribed_feedback: false) : attendees.and(unsubscribed: false).and(unsubscribed_feedback: false).and(id: account_id)
    recipients = recipients.map do |account|
      [account.email, EmailFields.recipient_variables(event: event, account: account).merge('feedback_token' => account.feedback_token_for(event))]
    end

    puts "#{log_prefix}: sending to #{recipients.count} recipient(s)"
    Mailer.deliver(
      :feedback,
      to: recipients,
      subject: EmailFields.replace_magic_tags(
        event.feedback_email_title || event.organisation.feedback_email_title,
        event: event,
        recipient_variables: true,
        plain_text: true
      ),
      locals: { event: event },
      from: ENV['FEEDBACK_EMAIL_FULL'],
      reply_to: event.email || event.organisation.try(:reply_to)
    )
    set(sent_feedback_requests_at: Time.now) if account_id == :all
    puts "#{log_prefix}: done sent_feedback_requests_at=#{sent_feedback_requests_at}"
  end

  def send_waitlist_tickets_available
    return unless organisation
    return unless tickets_available?
    return if waitships.empty?

    Mailer.deliver(
      :waitlist_tickets_available,
      to: waiters.and(unsubscribed: false),
      subject: "Tickets now available for #{name}",
      locals: { event: self },
      reply_to: email || organisation.try(:reply_to)
    )
  end

  def send_ticket_type_waitlist_tickets_available(ticket_type_id)
    return unless organisation
    return unless allow_ticket_type_waitlists?

    ticket_type = ticket_types.find(ticket_type_id)
    return unless ticket_type
    return unless ticket_type.tickets_available?
    return if ticket_type.ticket_type_waitships.empty?

    Mailer.deliver(
      :waitlist_tickets_available,
      to: Account.and(:id.in => ticket_type.ticket_type_waitships.pluck(:account_id).compact, unsubscribed: false),
      subject: "Tickets now available for #{ticket_type.name} at #{name}",
      locals: { event: self, ticket_type: ticket_type },
      reply_to: email || organisation.try(:reply_to)
    )
  end
end
