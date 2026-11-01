# Books tickets to an event and hands the order to a payment method: the
# steps behind the checkout form (POST /e/:slug/purchase), taking plain
# values so other callers, like agents, can book the same way.
#
# It checks who may book (Event#booking_restriction, for the signed-in account)
# and that each ticket type is still on sale. Failures raise an OrderBuilder::Error, after destroying any order created.
class OrderBuilder
  # Each error's message says what went wrong, for whoever is booking. The details of an unexpected error or a payment
  # provider's go to Sentry or the failed purchase email instead
  class Error < StandardError
    MESSAGE = 'Booking failed. Please try again.'.freeze

    def initialize(message = self.class::MESSAGE)
      super
    end

    def status
      400
    end
  end

  class AccountInvalid < Error
    MESSAGE = 'The name or email address is not valid.'.freeze
  end

  class PaymentFailed < Error
    MESSAGE = "The payment provider couldn't set up this payment. Please try again later.".freeze
  end

  class BannedEmail < Error
    MESSAGE = 'This account cannot book this event.'.freeze

    def status
      403
    end
  end

  class TicketTypeNotFound < Error
    MESSAGE = 'Ticket type not found.'.freeze

    def status
      404
    end
  end

  class NotEnoughTickets < Error
    MESSAGE = 'Not enough tickets left of that type.'.freeze
  end

  class SalesEnded < Error
    MESSAGE = 'Sales of that ticket type have ended.'.freeze
  end

  class MonthlyDonationRequired < Error
    MESSAGE = 'That ticket type is only for monthly donors giving at least its minimum.'.freeze
  end

  class NoTickets < Error
    MESSAGE = 'Choose at least one ticket.'.freeze
  end

  # The event asks for a donation to the organisation of at least its minimum_donation
  class DonationRequired < Error
    def initialize(minimum, currency)
      super("A donation of at least #{Money.new((minimum * 100).round, currency).format(no_cents_if_whole: true)} is required.")
    end
  end

  class PaymentMethodUnavailable < Error
    MESSAGE = "That payment method isn't available for this event.".freeze
  end

  class NotAllowed < Error
    MESSAGES = {
      locked: 'This event is not taking bookings right now.',
      monthly_donors_only: 'Only monthly donors to this organisation can book this event.',
      members_only: 'Only members can book this event.'
    }.freeze

    # What Event#booking_restriction gave: :locked, :monthly_donors_only or :members_only
    attr_reader :restriction

    def initialize(restriction)
      @restriction = restriction
      super(MESSAGES.fetch(restriction))
    end

    def status
      403
    end
  end

  class Duplicate < Error
    def status
      409
    end
  end

  attr_reader :order, :account

  # buyer: name, email, and optionally phone, postcode and country
  # quantities and prices: keyed by ticket type id
  # signed_in_account: whoever is signed in, if anyone; only they can update their profile or spend their credit
  def initialize(event:, buyer:, quantities:, payment_method:, prices: {}, signed_in_account: nil, new_account_currency: nil,
                 secret_ticket_type_id: nil, answers: nil, donation_amount: nil, donation_via_modal: false,
                 discount_code_id: nil, cohost: nil, affiliate_type: nil, affiliate_id: nil,
                 opt_in_organisation: false, opt_in_facilitator: false, hear_about: nil, via: nil, http_referrer: nil,
                 confirmed_duplicate: false, utm: {})
    @event = event
    @buyer = buyer
    @quantities = quantities
    @prices = prices || {}
    @payment_method = payment_method.to_s
    @signed_in_account = signed_in_account
    @new_account_currency = new_account_currency
    @secret_ticket_type_id = secret_ticket_type_id
    @answers = answers
    @donation_amount = donation_amount
    @donation_via_modal = donation_via_modal
    @discount_code_id = discount_code_id
    @cohost = cohost
    @affiliate_type = affiliate_type
    @affiliate_id = affiliate_id
    @opt_in_organisation = opt_in_organisation
    @opt_in_facilitator = opt_in_facilitator
    @hear_about = hear_about
    @via = via
    @http_referrer = http_referrer
    @confirmed_duplicate = confirmed_duplicate
    @utm = utm || {}
  end

  # Returns what the payment method returns (JSON for the checkout form)
  def call
    restriction = @event.booking_restriction(@signed_in_account)
    raise NotAllowed.new(restriction) if restriction
    # Donation's own validation only sees a donation that's made
    raise DonationRequired.new(@event.minimum_donation, @event.currency) if donation_below_minimum?

    find_or_create_account
    check_duplicate unless @confirmed_duplicate
    create_order
    create_tickets
    @event.refresh_sold_out_cache_and_notify_waitlist
    apply_donation_and_discounts
    process_payment
  rescue Error
    raise
  rescue StandardError => e
    info = EventPaymentMethod.purchase_error_for(e)
    if info && @order
      if info[:action] == :lock
        @order.event.set(locked: true, locked_error: EventPaymentMethod.purchase_error_message(e), locked_error_provider: info[:provider])
        @order.event.delete_atproto
      end
      @order.notify_of_failed_purchase(e, provider: info[:provider], help: info[:help])
      @order.destroy
      raise PaymentFailed
    end

    ErrorReporting.capture_exception(e, context: ({ order_id: @order.id.to_s } if @order))
    @order.try(:destroy)
    raise Error
  end

  private

  def find_or_create_account
    account_hash = @buyer.slice(:name, :email, :postcode, :country)
    account_hash[:phone] = @buyer[:phone] if @event.organisation.collect_phone?

    @account = Account.find_by(email: @buyer[:email].downcase.strip)
    @account ||= Account.new(account_hash.merge(skip_confirmation_email: true, default_currency: @new_account_currency, skip_geocoding: true))

    if @account.persisted?
      # Only the account owner may merge checkout fields into an existing profile.
      @account.update_attributes!(account_hash.compact) if signed_in_as_buyer?
    else
      begin
        @account.save!
      rescue StandardError
        raise AccountInvalid
      end
    end
    raise BannedEmail if @event.organisation.banned_emails_a.include?(@account.email)
  end

  def donation_below_minimum?
    @event.minimum_donation&.positive? && !@event.donations_to_dandelion? && @donation_amount.to_f < @event.minimum_donation
  end

  def signed_in_as_buyer?
    @signed_in_account && @signed_in_account.id == @account.id
  end

  def check_duplicate
    return unless @event.tickets.complete.and(
      '$or' => [
        { account_id: @account.id, :email.in => [nil, @account.email] },
        { email: @account.email }
      ]
    ).exists?

    raise Duplicate, "A ticket to #{@event.name} has already been booked for #{@account.email}."
  end

  def payment_method_object
    EventPaymentMethod.object(@payment_method)
  end

  def ignore_dandelion_donation?
    @event.donations_to_dandelion? && !payment_method_object&.platform_donations
  end

  def create_order
    @order = Order.create!(
      event: @event,
      account: @account,
      currency: payment_method_object&.order_currency_for(@event) || @event.currency,
      organisation_revenue_share: @event.organisation_revenue_share,
      revenue_sharer: (@event.revenue_sharer_organisationship.account if @event.revenue_sharer_organisationship),
      opt_in_organisation: @opt_in_organisation,
      opt_in_facilitator: @opt_in_facilitator,
      answers: @answers,
      application_fee_paid_to_dandelion: !ignore_dandelion_donation? && !@event.revenue_sharer_organisationship && @event.donations_to_dandelion?,
      donation_via_modal: !ignore_dandelion_donation? && @donation_via_modal,
      cohost: @cohost,
      affiliate_type: @affiliate_type,
      affiliate_id: @affiliate_id,
      discount_code_id: @discount_code_id,
      hear_about: @hear_about,
      via: @via,
      http_referrer: @http_referrer
    )
    # Not needed for the purchase, so looked up in the background, once the order has joined the account to its
    # organisations (whose local groups need the coordinates)
    @account.delay.geocode_location! if @account.skip_geocoding && @account.location
  end

  def create_tickets
    purchased = Hash.new(0)
    available = {}
    @quantities.each do |ticket_type_id, quantity|
      quantity = quantity.to_i
      next if quantity <= 0

      ticket_type = @event.ticket_types.find(ticket_type_id)
      # Hidden ticket types can only be bought via their secret link
      if !ticket_type || (ticket_type.hidden && @secret_ticket_type_id != ticket_type.public_id)
        @order.destroy
        raise TicketTypeNotFound
      end
      # Ticket's own validation also refuses these, but as an unexpected error
      if ticket_type.sales_ended? || @event.sales_closed_due_to_event_end?
        @order.destroy
        raise SalesEnded
      end
      if ticket_type.monthly_donation_too_low?(@account)
        @order.destroy
        raise MonthlyDonationRequired
      end
      purchased[ticket_type.id] += quantity
      available[ticket_type.id] ||= ticket_type.number_of_tickets_available_in_single_purchase
      if purchased[ticket_type.id] > available[ticket_type.id]
        @order.destroy
        raise NotEnoughTickets
      end
      price = if ticket_type.range || ticket_type.price.nil?
                submitted_price = Float(@prices[ticket_type_id], exception: false) || 0
                ticket_type.range ? submitted_price.clamp(*ticket_type.range) : submitted_price
              end
      quantity.times do
        @order.tickets.create!(
          event: @event,
          account: @account,
          ticket_type: ticket_type,
          price: price,
          skip_event_refresh: true
        )
      end
      # Count these tickets when checking availability for the next ticket type
      @event.reset_ticket_counts
    end
    return unless @order.tickets.empty?

    @order.destroy
    raise NoTickets
  end

  def apply_donation_and_discounts
    @order.donations.create!(event: @event, account: @account, amount: @donation_amount) if @donation_amount.to_f > 0 && !ignore_dandelion_donation?

    @order.filter_discounts if @order.discount_code && @order.discount_code.filter
    # Credit belongs to the order account; only apply it if that account is signed in.
    @order.apply_credit if signed_in_as_buyer?
    @order.apply_fixed_discount
    @order.set(original_description: @order.description)
  end

  def process_payment
    pm = if @order.total > 0
           payment_method_object
         else
           EventPaymentMethod.object('rsvp')
         end
    if (@order.total.positive? && pm&.name == 'rsvp') || !pm&.process || !pm.available?(@event)
      @order.destroy
      raise PaymentMethodUnavailable
    end

    pm.process_payment(order: @order, event: @event, account: @account, cohost: @cohost, utm: @utm)
  end
end
