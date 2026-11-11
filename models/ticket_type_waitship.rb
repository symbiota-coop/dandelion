class TicketTypeWaitship
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account
  belongs_to_without_parent_validation :ticket_type

  validates_uniqueness_of :account, scope: :ticket_type

  validate :eligible_for_ticket_type_waitlist, on: :create

  after_create do
    ticket_type.refresh_sold_out_cache_and_notify_waitlist if ticket_type
    send_notification if ticket_type&.event&.send_order_notifications
  end

  def send_notification
    event = ticket_type.event
    Mailer.deliver(
      :waitlist,
      to: event.event_facilitators,
      subject: "New waitlist registration for #{event.name}",
      locals: { account: account, event: event, ticket_type: ticket_type }
    )
  end
  handle_asynchronously :send_notification

  private

  # Matches checkout UX: join only when sales are open but this ticket type has no checkout availability.
  def eligible_for_ticket_type_waitlist
    return unless ticket_type

    event = ticket_type.event

    unless event&.allow_ticket_type_waitlists?
      errors.add(:base, 'Ticket type waitlists are not enabled for this event.')
      return
    end

    if ticket_type.sales_ended?
      errors.add(:base, 'Sales are closed for this ticket.')
      return
    end

    if event&.sales_closed_due_to_event_end?
      errors.add(:base, 'Sales are closed for this ticket.')
      return
    end

    if ticket_type.number_of_tickets_available_in_single_purchase.to_i.positive?
      errors.add(:base, 'This ticket type is not sold out.')
      return
    end
  end
end
