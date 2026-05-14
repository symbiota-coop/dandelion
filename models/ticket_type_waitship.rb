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
  end

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

    # rubocop:disable Style/GuardClause, Style/RedundantReturn -- explicit branch like sales checks above; keep trailing return for symmetry
    if ticket_type.number_of_tickets_available_in_single_purchase.to_i.positive?
      errors.add(:base, 'This ticket type is not sold out.')
      return
    end
    # rubocop:enable Style/GuardClause, Style/RedundantReturn
  end
end
