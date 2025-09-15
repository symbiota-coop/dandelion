class Ticket
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  include Mongoid::Paranoia
  include TicketNotifications

  belongs_to_without_parent_validation :event, index: true
  belongs_to_without_parent_validation :account, index: true, optional: true
  belongs_to_without_parent_validation :order, index: true, optional: true
  belongs_to_without_parent_validation :ticket_type, index: true, optional: true
  belongs_to_without_parent_validation :zoomship, index: true, optional: true

  has_many :notifications, as: :notifiable, dependent: :destroy

  attr_accessor :complementary, :prevent_notifications

  field :price, type: Float
  field :discounted_price, type: Float
  ### from order
  field :currency, type: String
  field :percentage_discount, type: Integer
  field :percentage_discount_monthly_donor, type: Integer
  field :organisation_revenue_share, type: Float
  field :session_id, type: String
  field :payment_intent, type: String
  field :show_attendance, type: Boolean
  field :subscribed_discussion, type: Boolean
  field :checked_in, type: Boolean
  field :checked_in_at, type: Time
  field :name, type: String
  field :email, type: String
  field :payment_completed, type: Boolean
  field :transferred, type: Boolean
  field :made_available_at, type: Time
  field :original_ticket_type_name, type: String

  def self.admin_fields
    {
      summary: { type: :text, edit: false },
      price: :number,
      discounted_price: :number,
      percentage_discount: :number,
      percentage_discount_monthly_donor: :number,
      currency: :text,
      payment_completed: :check_box,
      organisation_revenue_share: :number,
      show_attendance: :check_box,
      checked_in: :check_box,
      name: :text,
      email: :email,
      event_id: :lookup,
      account_id: :lookup,
      order_id: :lookup,
      ticket_type_id: :lookup,
      zoomship_id: :lookup
    }
  end

  before_validation do
    if email
      self.email = email.downcase.strip
      e = EmailAddress.error(email)
      errors.add(:email, "- #{e}") if e
    end

    self.price = ticket_type.price if !price && !complementary && ticket_type && ticket_type.price
    errors.add(:price, 'is too low') if price && ticket_type && ticket_type.range_min && price < ticket_type.range_min

    self.payment_completed = true if complementary || price.nil? || price == 0

    self.original_ticket_type_name = ticket_type.name if ticket_type && !original_ticket_type_name
    self.currency = (order.try(:currency) || event.try(:currency)) unless currency
    self.organisation_revenue_share = order.try(:organisation_revenue_share) unless organisation_revenue_share
    self.percentage_discount = order.try(:percentage_discount) unless percentage_discount
    self.percentage_discount_monthly_donor = order.try(:percentage_discount_monthly_donor) unless percentage_discount_monthly_donor

    self.discounted_price = calculate_discounted_price

    if new_record?
      unless complementary
        errors.add(:ticket_type, 'is full') if ticket_type && (ticket_type.number_of_tickets_available_in_single_purchase < 1)
        errors.add(:ticket_type, 'is not available as sales have ended') if ticket_type && ticket_type.sales_end && Time.now > ticket_type.sales_end
        if ticket_type && ticket_type.minimum_monthly_donation && (
            !account ||
            !(organisationship = event.organisation.organisationships.find_by(account: account)) ||
            !organisationship.monthly_donation_amount ||
            Money.new(organisationship.monthly_donation_amount * 100, organisationship.monthly_donation_currency) < Money.new(ticket_type.minimum_monthly_donation * 100, event.currency)
          )
          errors.add(:ticket_type, 'is not available to someone donating this amount')
        end
      end
      errors.add(:account, 'already has a ticket to this event') if event && zoomship && event.tickets.complete.find_by(account: account)
    end
  end

  def payment_completed!
    if event.enable_resales? && ticket_type.remaining_including_made_available < 0 && (ticket = ticket_type.tickets.and(:made_available_at.ne => nil).order('made_available_at asc').first)
      account = ticket.account
      ticket.refund
      ticket.destroy
      send_resale_notification_to_previous_ticketholder(account)
      send_resale_notification_to_organiser(account)
    end
    event.waitships.find_by(account: account).try(:destroy)
    event.gathering.memberships.create(account: account, unsubscribed: true) if event.gathering
  end

  after_save do
    if event
      event.clear_cache
      event.set(sold_out_cache: event.sold_out?)
    end
  end
  after_destroy do
    if event
      event.clear_cache
      event.set(sold_out_cache: event.sold_out?)
    end
  end

  def self.email_viewer?(ticket, account)
    account && (!ticket.order || Order.email_viewer?(ticket.order, account))
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def self.incomplete
    self.and(:payment_completed.ne => true)
  end

  def self.complete
    self.and(payment_completed: true)
  end

  def self.discounted
    self.and(:id.in => self.and(:percentage_discount.ne => nil).pluck(:id) + self.and(:percentage_discount_monthly_donor.ne => nil).pluck(:id))
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

  after_create :update_zoomship_tickets_count, if: :zoomship
  after_destroy :update_zoomship_tickets_count, if: :zoomship
  def update_zoomship_tickets_count
    zoomship.update_attribute(:tickets_count, zoomship.tickets.count)
  end

  def refund
    return unless event.refund_deleted_orders && event.organisation && discounted_price && discounted_price > 0 && payment_completed && payment_intent

    # begin
    Stripe.api_key = event.organisation.stripe_connect_json ? ENV['STRIPE_SK'] : event.organisation.stripe_sk
    Stripe.api_version = '2020-08-27'
    pi = Stripe::PaymentIntent.retrieve payment_intent, { stripe_account: event.organisation.stripe_user_id }.compact

    # to handle cases where there was an order-wide discount applied
    refund_amount = order ? [discounted_price, order.total].min : discounted_price
    return if refund_amount <= 0

    if event.revenue_sharer_organisationship
      Stripe::Refund.create(
        amount: (refund_amount * 100).to_i,
        charge: pi.charges.first.id,
        refund_application_fee: true,
        reverse_transfer: true
      )
    else
      Stripe::Refund.create({
                              amount: (refund_amount * 100).to_i,
                              charge: pi.charges.first.id
                            }, { stripe_account: event.organisation.stripe_user_id }.compact)
    end
  rescue Stripe::InvalidRequestError => e
    notify_of_failed_refund(e)
    true
  end
end
