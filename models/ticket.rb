class Ticket
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  include Mongoid::Paranoia
  include Refundable
  include TicketNotifications
  include TicketPaymentMethods
  include PublicToken

  belongs_to_without_parent_validation :event
  belongs_to_without_parent_validation :account, optional: true
  belongs_to_without_parent_validation :order, optional: true
  belongs_to_without_parent_validation :ticket_type, optional: true
  has_many :notifications, as: :notifiable, dependent: :destroy

  attr_accessor :complimentary, :prevent_notifications, :skip_event_refresh

  field :price, type: Float
  field :discounted_price, type: Float
  field :id_string, type: String
  ### from order
  field :currency, type: String
  field :percentage_discount, type: Integer
  field :percentage_discount_monthly_donor, type: Integer
  field :organisation_revenue_share, type: Float
  field :checked_in, type: Boolean
  field :checked_in_at, type: Time
  field :name, type: String
  field :email, type: String
  field :payment_completed, type: Boolean
  field :transferred, type: Boolean
  field :made_available_at, type: Time
  field :original_ticket_type_name, type: String

  def self.protected_attributes
    %w[payment_completed token]
  end

  validates_same_parent :ticket_type, via: :event

  before_validation do
    if email
      self.email = email.downcase.strip
      e = EmailAddress.error(email)
      errors.add(:email, "- #{e}") if e
    end

    self.id_string = id.to_s if id && !id_string

    self.price = ticket_type.price if !price && !complimentary && ticket_type && ticket_type.price
    variable_price_ticket = ticket_type && (ticket_type.range || ticket_type.price.nil?)
    if variable_price_ticket && !complimentary
      if !price&.finite?
        errors.add(:price, 'must be a number')
      elsif ticket_type.range
        self.price = price.clamp(*ticket_type.range)
      elsif price < 0
        errors.add(:price, 'is too low')
      end
    end

    self.payment_completed = true if complimentary || price == 0 || (price.nil? && !variable_price_ticket)

    self.original_ticket_type_name = ticket_type.name if ticket_type && !original_ticket_type_name
    self.currency = (order.try(:currency) || event.try(:currency)) unless currency
    self.organisation_revenue_share = order.try(:organisation_revenue_share) unless organisation_revenue_share
    self.percentage_discount = order.try(:percentage_discount) unless percentage_discount
    self.percentage_discount_monthly_donor = order.try(:percentage_discount_monthly_donor) unless percentage_discount_monthly_donor

    self.discounted_price = calculate_discounted_price

    if new_record? && !complimentary
      errors.add(:ticket_type, 'is full') if ticket_type && (ticket_type.number_of_tickets_available_in_single_purchase < 1)
      errors.add(:ticket_type, 'is not available as sales have ended') if (ticket_type && ticket_type.sales_ended?) || (event && event.sales_closed_due_to_event_end?)
      errors.add(:ticket_type, 'is not available to someone donating this amount') if ticket_type&.monthly_donation_too_low?(account)
    end
  end

  # The oldest ticket on resale whose place this one took: of its type when the type's quantity is past, of its ticket
  # group when the group's capacity is, or of the event when the event's is. Counting tickets on resale, as they still
  # hold their places until they're removed. Only a ticket that takes places can take another's place in a group or
  # the event, and only from a ticket that takes places: a zero-slot add-on ignores capacity, so it mustn't settle an
  # admission's resale (whose excess may be an unpaid hold), nor an admission an add-on's
  def ticket_on_resale_replaced
    return unless ticket_type

    on_resale = event.tickets.and(:made_available_at.ne => nil).order('made_available_at asc')
    return on_resale.and(ticket_type_id: ticket_type_id).first if ticket_type.remaining_including_made_available < 0
    return unless ticket_type.slots.positive?

    if (group = ticket_type.ticket_group) && group.capacity - group.tickets.slots_taken < 0
      on_resale.and(:ticket_type_id.in => group.ticket_types.to_a.select { |t| t.slots.positive? }.map(&:id)).first
    elsif event.capacity && event.capacity - event.tickets.slots_taken < 0
      on_resale.and(:ticket_type_id.nin => event.ticket_types.to_a.reject { |t| t.slots.positive? }.map(&:id)).first
    end
  end

  # Whether this ticket on resale can go back in the ticket counts. Its place may already be held by a ticket that isn't
  # paid for yet, and putting it back as well would overbook the event: it stays on resale until the hold is paid for,
  # which refunds and removes it (payment_completed!), or let go. Fresh from the database, as the last one put back counts
  def fits_back_in_counts?
    remaining = if ticket_type_id && (ticket_type = TicketType.find(ticket_type_id))
                  ticket_type.wiser_remaining
                else
                  Event.find(event_id).places_remaining
                end
    remaining.nil? || remaining >= 1
  end

  # The tickets on resale whose places this one took, until they've freed as many places as it takes: one of its own
  # type frees as many, but a ticket taking two places can take those of two that take one. Each is claimed as it's
  # found, by removing it there and then, so that payments completing at once resell different tickets
  def claim_tickets_on_resale_replaced
    places = ticket_type ? ticket_type.slots : 1
    claimed = []
    while (claimed.empty? || places.positive?) && (resold_ticket = ticket_on_resale_replaced)
      next if Ticket.collection.update_one(
        { _id: resold_ticket.id, made_available_at: { '$ne' => nil }, deleted_at: nil },
        { '$set' => { deleted_at: Time.now } }
      ).modified_count.zero?

      claimed << resold_ticket
      places -= resold_ticket.ticket_type ? resold_ticket.ticket_type.slots : 1
    end
    claimed
  end

  # Refunds a ticket on resale whose place this one took, removes it, and emails its holder and the organisers. This
  # ticket's payment has completed, so errors are reported rather than raised: raised, they'd stop its order
  # completing, and its tickets would never be sent
  def complete_resale(resold_ticket)
    resold_account = resold_ticket.account
    requires_manual_refund = resold_ticket.requires_manual_refund?
    gocardless_instalment = resold_ticket.gocardless_billing_request_id.present?
    # What the order paid, as the ticket's price may be more than was paid for it. Its value, set when it was paid for, as
    # its total leaves out its tickets that have been resold, including those this sale resells. Orders paid for with
    # nothing (RSVPs) have none
    order_total = resold_ticket.order.value || 0 if resold_ticket.order_discounted_as_a_whole?
    refund_amount = resold_ticket.discounted_price
    refund_currency = resold_ticket.currency
    # Left for the organisers to refund if refunding raises
    requires_manual_refund = !reporting_resale_errors(resold_ticket) { resold_ticket.refund } unless requires_manual_refund
    reporting_resale_errors(resold_ticket) { resold_ticket.destroy }
    reporting_resale_errors(resold_ticket) do
      send_resale_notification_to_previous_ticketholder(
        resold_account,
        requires_manual_refund: requires_manual_refund,
        gocardless_instalment: gocardless_instalment
      )
    end
    reporting_resale_errors(resold_ticket) do
      send_resale_notification_to_organiser(
        resold_account,
        requires_manual_refund: requires_manual_refund,
        gocardless_instalment: gocardless_instalment,
        refund_amount: refund_amount,
        order_total: order_total,
        currency: refund_currency
      )
    end
  end

  # Whether the block ran without raising
  def reporting_resale_errors(resold_ticket)
    yield
    true
  rescue StandardError => e
    ErrorReporting.capture_exception(e, context: { ticket_id: id.to_s, resold_ticket_id: resold_ticket.id.to_s })
    false
  end

  def payment_completed!
    # Not only while the event allows resales: tickets left on resale when they were turned off are those whose places
    # were already held (Event#put_back_tickets_on_resale_that_fit)
    claim_tickets_on_resale_replaced.each { |resold_ticket| complete_resale(resold_ticket) }
    event.waitships.find_by(account: account).try(:destroy)
    ticket_type.ticket_type_waitships.find_by(account: account).try(:destroy) if ticket_type && account
    event.gathering.memberships.create(account: account, unsubscribed: true) if event.gathering
  end

  after_save do
    # Purchases create several tickets and refresh the event once afterwards
    event.refresh_sold_out_cache_and_notify_waitlist if event && !event.flagged_for_destroy? && !skip_event_refresh
  end
  after_destroy do
    if event && !event.flagged_for_destroy?
      # A place this held may be one a ticket on resale was left waiting for
      event.put_back_tickets_on_resale_that_fit unless event.enable_resales?
      event.refresh_sold_out_cache_and_notify_waitlist
    end
  end
  after_restore do
    event.refresh_sold_out_cache_and_notify_waitlist if event && !event.flagged_for_destroy?
  end

  # Like free orders, free tickets without an order can be cancelled by their account
  def cancellable?
    order_id.nil? && account_id && !email && payment_completed && (discounted_price.nil? || discounted_price.zero?)
  end

  def self.email_viewer?(ticket, account, order_email_viewer: nil)
    account && (!ticket.order || order_email_viewer || (order_email_viewer.nil? && Order.email_viewer?(ticket.order, account)))
  end

  def api_hash(viewer)
    email_visible = Ticket.email_viewer?(self, viewer)
    {
      id: id.to_s,
      name: account ? account.name : '',
      firstname: account ? account.firstname : '',
      lastname: account ? account.lastname : '',
      email: email_visible && account ? account.email : '',
      ordered_for_name: name,
      ordered_for_email: email_visible ? email : '',
      ticket_type: ticket_type.try(:name),
      price: discounted_price,
      currency: currency,
      checked_in: checked_in,
      checked_in_at: checked_in_at&.iso8601,
      order_id: order_id&.to_s,
      created_at: created_at.iso8601
    }
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def self.counts_by_type
    collection.aggregate(
      [
        { '$match' => criteria.selector },
        { '$group' => { '_id' => '$ticket_type_id', 'count' => { '$sum' => 1 } } }
      ]
    ).each_with_object(Hash.new(0)) { |row, hash| hash[row['_id']] = row['count'] }
  end

  def self.slots_taken
    counts = counts_by_type
    return 0 if counts.empty?

    slots_by_id = TicketType.and(:id.in => counts.keys.compact).each_with_object({}) do |ticket_type, hash|
      hash[ticket_type.id] = ticket_type.slots
    end
    counts.sum { |type_id, count| count * (type_id ? slots_by_id.fetch(type_id, 1) : 1) }
  end

  def self.incomplete
    self.and(payment_completed: false)
  end

  def self.complete
    self.and(payment_completed: true)
  end

  # Tickets created by admins (complimentary tickets) have no order
  def self.without_order
    self.and(order_id: nil)
  end

  def self.discounted
    self.and(:id.in => self.and(:percentage_discount.ne => nil).pluck(:id) + self.and(:percentage_discount_monthly_donor.ne => nil).pluck(:id))
  end

  HOME_PAGE_STATS_DEFAULTS = {
    ticket_count: 0, worth_gbp_integer: 0, average_rating: nil, rating_count: 0
  }.freeze

  # Sample figures, for the design guide and the home on development
  HOME_PAGE_STATS_SAMPLE = {
    ticket_count: 204_333, worth_gbp_integer: 7_450_000, average_rating: 4.6, rating_count: 9300
  }.freeze

  def self.home_page_stats
    raw = Stash.find_by(key: 'public_home_ticket_stats')&.value
    return HOME_PAGE_STATS_DEFAULTS if raw.blank?

    HOME_PAGE_STATS_DEFAULTS.merge(JSON.parse(raw).symbolize_keys.slice(*HOME_PAGE_STATS_DEFAULTS.keys))
  rescue JSON::ParserError
    HOME_PAGE_STATS_DEFAULTS
  end

  def self.refresh_home_page_stats!
    m = Money.new(0, 'GBP')
    Order.and(:value.ne => nil, :currency.in => FIAT_CURRENCIES).each do |o|
      m += Money.new(o.value * 100, o.currency)
    rescue StandardError
      # Leave out orders that can't be converted to GBP (e.g. no exchange rate for their currency)
    end
    rated = EventFeedback.rated
    stats = {
      ticket_count: count,
      worth_gbp_integer: Float('%.3g' % m).to_i,
      average_rating: rated.avg(:rating)&.round(1),
      rating_count: rated.count
    }
    Stash.find_or_initialize_by(key: 'public_home_ticket_stats').tap do |stash|
      stash.value = stats.to_json
      stash.save!
    end
    stats
  end

  def incomplete?
    !payment_completed
  end

  def complete?
    payment_completed
  end

  def firstname
    return if name.blank?

    parts = name.split
    n = if parts.count > 1 && %w[mr mrs ms dr].include?(parts[0].downcase.gsub('.', ''))
          parts[1]
        else
          parts[0]
        end
    n.capitalize
  end

  def calculate_discounted_price
    return unless price

    p = price.to_f
    p *= ((100 - (percentage_discount || 0)).to_f / 100)
    p *= ((100 - (percentage_discount_monthly_donor || 0)).to_f / 100)
    p.round(2)
  end

  def summary
    "#{event.try(:name)} : #{account.email} : #{ticket_type.try(:name)}"
  end

  def circle
    account
  end

  # When resold. Credit and fixed discounts come off an order as a whole rather than off its tickets, so a ticket's own
  # price can be more than was paid for it, and refunding it would refund the holder more than they paid
  def requires_manual_refund?
    discounted_price && discounted_price > 0 && payment_completed && (!refundable? || order_discounted_as_a_whole?)
  end

  def order_discounted_as_a_whole?
    order && ((order.credit_applied || 0) > 0 || (order.fixed_discount_applied || 0) > 0)
  end

  def refund
    return unless event && event.organisation && discounted_price && discounted_price > 0 && payment_completed && refundable?

    # order.total counts this ticket even once it's removed, as a ticket on resale is when a sale claims it, before it's
    # refunded: loading a ticket's order puts the ticket in that order's tickets (Mongoid's belongs_to binding), whatever
    # the database says. So read the order through this ticket, not afresh, or a resold ticket's refund leaves it out
    refund_amount = order ? [discounted_price, order.total].min : discounted_price
    return if refund_amount <= 0

    refund_payment(amount: refund_amount)
  end
end
