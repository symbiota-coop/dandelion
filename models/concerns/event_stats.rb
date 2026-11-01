module EventStats
  extend ActiveSupport::Concern

  class_methods do
    # What the stats table and CSV (event_stats_row/) read of each event
    def with_stats_includes
      includes(
        :organisation, :coordinator, :organiser, :revenue_sharer, :ticket_types, :stripe_charges, :orders, :rpayments, :event_feedbacks,
        activity: :organisation, local_group: :organisation, cohostships: :organisation,
        event_facilitations: :account, event_tagships: :event_tag
      )
    end

    # Loads events for the stats table and CSV with one query per collection, rather than a few dozen queries per
    # event: their own records are included, and each event is handed the fields of its tickets and donations (plucked,
    # as loading them all would be slow) and its ticket counts, so its sums and slots_taken read those
    def preload_stats(events)
      events = events.with_stats_includes.to_a
      event_ids = events.map(&:id)
      rows = lambda do |model, fields, row_class|
        model.and(:event_id.in => event_ids).pluck(:event_id, *fields).each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |(event_id, *values), rows_by_event|
          rows_by_event[event_id] << row_class.new(*values)
        end
      end
      ticket_rows = rows.call(Ticket, EventAccounting::TICKET_ACCOUNTING_FIELDS, EventAccounting::TicketAccountingRow)
      donation_rows = rows.call(Donation, EventAccounting::DONATION_ACCOUNTING_FIELDS, EventAccounting::DonationAccountingRow)
      transferred_order_ids = Order.and(:id.in => events.flat_map { |event| event.stripe_charges.filter_map(&:order_id) }.uniq, transferred: true).pluck(:id).to_set
      events.each do |event|
        event.assign_preloaded_stats(
          ticket_rows: ticket_rows[event.id],
          donation_rows: donation_rows[event.id],
          transferred_order_ids: transferred_order_ids
        )
      end
      preload_split_order_revenue(events.flat_map(&:orders_for_accounting))
      events
    end

    # The orders whose credit or fixed discount is split with a revenue sharer read their tickets' and donations'
    # revenue, so they're handed it, read for all of them at once
    def preload_split_order_revenue(orders)
      orders = orders.select { |order| order.revenue_sharer_id && ((order.credit_applied || 0).positive? || (order.fixed_discount_applied || 0).positive?) }
      return if orders.empty?

      order_ids = orders.map(&:id)
      ticket_prices = Ticket.and(:order_id.in => order_ids).pluck(:order_id, :discounted_price, :currency).group_by(&:first)
      donation_amounts = Donation.and(:order_id.in => order_ids).pluck(:order_id, :amount, :currency).group_by(&:first)
      orders.each do |order|
        revenue = ->(rows) { (rows || []).inject(Money.new(0, order.currency)) { |r, (_, amount, currency)| r + Money.new((amount || 0) * 100, currency) } }
        order.assign_preloaded_revenue(discounted_ticket_revenue: revenue.call(ticket_prices[order.id]), donation_revenue: revenue.call(donation_amounts[order.id]))
      rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
        # Left to read its tickets and donations itself, as the event's sums rescue this
        next
      end
    end
  end

  def assign_preloaded_stats(ticket_rows:, donation_rows:, transferred_order_ids:)
    @ticket_accounting_rows = ticket_rows
    @donation_accounting_rows = donation_rows
    @transferred_order_ids = transferred_order_ids
    # As ticket_counts: the tickets that weren't made available again, by type
    @ticket_counts = ticket_rows.reject(&:made_available_at).map(&:ticket_type_id).tally.tap { |counts| counts.default = 0 }
    @stats_preloaded = true
  end

  # The progress bar shows these on other pages too, where counting is cheaper than plucking every ticket and order
  def ticket_count
    @stats_preloaded ? ticket_accounting_rows.size : tickets.count
  end

  def incomplete_orders?
    @stats_preloaded ? orders.any? { |order| order.payment_completed == false } : orders.incomplete.exists?
  end

  def complete_ticket_rows
    ticket_accounting_rows.select { |ticket| ticket.payment_completed == true }
  end

  # The distinct accounts with complete tickets, as attendees.count
  def attendees_count
    complete_ticket_rows.filter_map(&:account_id).uniq.size
  end

  def feedback_count
    event_feedbacks.to_a.size
  end

  # As EventFeedback.average_rating
  def average_feedback_rating
    ratings = event_feedbacks.filter_map(&:rating)
    (ratings.sum.to_f / ratings.length).round(1) if ratings.any?
  end
end
