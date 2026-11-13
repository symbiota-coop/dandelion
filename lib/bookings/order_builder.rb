# Books tickets to an event and hands the order to a payment method: the
# steps behind the checkout form (POST /e/:slug/purchase), taking plain
# values so other callers, like agents, can book the same way.
#
# It checks everything the checkout form asks for, as a request needn't come from the form: who may book
# (Event#booking_restriction, for the signed-in account), that each ticket type is still on sale, the terms, answers
# to the event's questions, and, with Quote, prices for range and pay-what-you-want tickets, the discount code and any
# donation. Failures raise an OrderBuilder::Error, after destroying any order created.
#
# The order's credit, fixed discount and donation are the Quote's, the one the checkout form showed the buyer. Its
# tickets are priced as they're created (Ticket, Order), and the order is refused unless they come to the quote's.
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

  class TermsNotAccepted < Error
    MESSAGE = 'You must agree to the terms and conditions.'.freeze
  end

  # Says which questions: an unknown one, an option that isn't offered or a required one left unanswered
  class AnswersInvalid < Error; end

  # A range or pay-what-you-want ticket without a price, or with one outside its range. Says which, and what's allowed
  class PriceInvalid < Error; end

  # Not one of the event's, used up, or not for every ticket chosen. Says which
  class DiscountCodeInvalid < Error; end

  class DonationInvalid < Error
    MESSAGE = "This event doesn't take donations at checkout.".freeze
  end

  # A donation to Dandelion below the currency's smallest unit (Event#checkout_donation's minimum)
  class DonationTooSmall < Error
    def initialize(minimum, currency)
      super("A donation to Dandelion must be at least #{Money.new((minimum * 100).round, currency).format(no_cents_if_whole: true)}, or nothing.")
    end
  end

  # The event asks for a donation to the organisation of at least its minimum_donation
  class DonationRequired < Error
    def initialize(minimum, currency)
      super("A donation of at least #{Money.new((minimum * 100).round, currency).format(no_cents_if_whole: true)} is required.")
    end
  end

  # Other bookings held the event, its discount code or the buyer's credit for longer than RecordLock waits
  class Busy < Error
    MESSAGE = 'Lots of people are booking at once. Please try again.'.freeze

    def status
      503
    end
  end

  class PaymentMethodUnavailable < Error
    MESSAGE = "That payment method isn't available for this event.".freeze
  end

  # Another request with the same idempotency key created its order first
  # (orders' unique index on event_id, account_id and idempotency_key)
  class IdempotencyKeyTaken < Error; end

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

  # The tickets came to a different price from the quote's: a bug, so reported, and nothing is charged
  class QuoteMismatch < StandardError; end

  # Bookings for someone, made by anyone who isn't signed in as them with their email confirmed, are limited per email
  # (RecipientLimit), as each can email them tickets. Signing up signs in before the email is confirmed, so being signed
  # in alone doesn't show the address is theirs
  class TooManyBookings < Error
    MESSAGE = "There have been several bookings for this email address in the last hour. Please sign in to book, or try again later.".freeze

    def status
      429
    end
  end

  class Duplicate < Error
    def status
      409
    end
  end

  # The email typed in is a slip from a common provider's (EmailTypos), so the tickets would go nowhere. The buyer can
  # confirm it with confirmed_email
  class EmailLooksMistyped < Error
    attr_reader :email

    def initialize(email)
      @email = email
      super("You entered your email address as #{email}, which looks mistyped.")
    end

    def status
      409
    end
  end

  attr_reader :order, :account, :quote

  # buyer: name, email, and optionally phone, postcode and country, of which only those the event asks for
  # (Event#checkout_buyer_fields) are used
  # quantities and prices: keyed by ticket type id
  # answers: keyed by question index (Questions.parse), as the checkout form sends them or as booleans and arrays
  # (Questions.answer_pairs)
  # discount_code: the code the buyer applied
  # signed_in_account: whoever is signed in, if anyone; only they can update their profile or spend their credit
  # default_dandelion_donation: without a donation_amount, add the smallest donation to Dandelion there can be
  # (Event#default_dandelion_donation)
  def initialize(event:, buyer:, quantities:, payment_method:, prices: {}, signed_in_account: nil, new_account_currency: nil,
                 secret_ticket_type_id: nil, answers: nil, accepted_terms: false, donation_amount: nil, donation_via_modal: false,
                 discount_code: nil, cohost: nil, affiliate_type: nil, affiliate_id: nil,
                 opt_in_organisation: false, opt_in_facilitator: false, hear_about: nil, via: nil, http_referrer: nil,
                 confirmed_duplicate: false, confirmed_email: false, utm: {}, idempotency_key: nil, default_dandelion_donation: false)
    @event = event
    @buyer = buyer
    # The checkout form sends no quantities when no ticket is chosen (blanks_to_nils)
    @quantities = Quote.quantities_from(quantities)
    @prices = prices || {}
    @payment_method = payment_method.to_s
    @signed_in_account = signed_in_account
    @new_account_currency = new_account_currency
    @secret_ticket_type_id = secret_ticket_type_id
    @answers = answers
    @accepted_terms = accepted_terms
    @donation_amount = donation_amount
    @donation_via_modal = donation_via_modal
    @discount_code = discount_code
    @cohost = cohost
    @affiliate_type = affiliate_type
    @affiliate_id = affiliate_id
    # Only the opt-ins and question the event offers
    offered = @event.checkout_opt_ins.map { |opt_in| opt_in[:name] }
    @opt_in_organisation = opt_in_organisation && offered.include?('opt_in_organisation')
    @opt_in_facilitator = opt_in_facilitator && offered.include?('opt_in_facilitator')
    @hear_about = (hear_about if @event.ask_hear_about)
    @via = via
    @http_referrer = http_referrer
    @confirmed_duplicate = confirmed_duplicate
    @confirmed_email = confirmed_email
    @default_dandelion_donation = default_dandelion_donation
    @utm = utm || {}
    @idempotency_key = idempotency_key
  end

  # Returns what the payment method returns (JSON for the checkout form)
  def call
    restriction = @event.booking_restriction(@signed_in_account)
    raise NotAllowed.new(restriction) if restriction

    check_choices
    check_email unless @confirmed_email
    find_or_create_account
    check_duplicate unless @confirmed_duplicate
    # After check_duplicate, so its warning and the booking confirmed after it count once
    raise TooManyBookings unless (signed_in_as_buyer? && @account.email_confirmed?) || RecipientLimit.allow?(:guest_booking, @account.email)
    # Checking what's left and taking it aren't one step, so bookings at once take turns from the quote to the order's
    # discounts: otherwise two could each see the last place, the code's last use or the whole of the buyer's credit,
    # and each take it. The payment provider is called after, once the order and its tickets hold what they took
    RecordLock.hold(*booking_locks) do
      # Worked out now, before the order counts as a use of its discount code, and checked again: another booking may
      # have used up the code since check_choices
      @quote = build_quote(account: @account, credit: signed_in_as_buyer?).validate!.tap(&:total)
      create_order
      create_tickets
      apply_donation_and_discounts
    end
    @event.refresh_sold_out_cache_and_notify_waitlist
    process_payment
  rescue Error
    raise
  rescue RecordLock::Busy
    @order.try(:destroy)
    raise Busy
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

  # What the checkout form asks the buyer to choose, before anything is made
  def check_choices
    raise TermsNotAccepted if @event.terms_acceptance_required? && !@accepted_terms

    @answer_pairs, error = Questions.answer_pairs(@event.questions, @answers)
    raise AnswersInvalid, error if error

    chosen = @quantities.select { |_ticket_type_id, quantity| quantity.to_i.positive? }
    raise NoTickets if chosen.empty?

    # Ticket types, prices, the discount code and the donation, before an account is made
    @chosen_discount_code = build_quote.validate!.discount_code
  end

  def build_quote(account: nil, credit: false)
    Quote.new(event: @event, quantities: @quantities, prices: @prices, account: account, credit: credit, discount_code: @discount_code,
              donation_amount: @donation_amount, payment_method: @payment_method, secret_ticket_type_id: @secret_ticket_type_id,
              default_dandelion_donation: @default_dandelion_donation)
  end

  # Only an email typed in: a signed-in buyer's is their account's
  def check_email
    email = @buyer[:email].to_s.strip
    return if @signed_in_account && @signed_in_account.email.casecmp?(email)

    raise EmailLooksMistyped, email if EmailTypos.mistyped?(email)
  end

  def find_or_create_account
    fields = @event.checkout_buyer_fields.map { |field| field[:name].to_sym } - [:hear_about]
    account_hash = @buyer.slice(*fields)

    @account = Account.find_by(email: @buyer[:email].downcase.strip)
    @account ||= Account.new(account_hash.merge(skip_confirmation_email: true, default_currency: @new_account_currency, skip_geocoding: true))

    if @account.persisted?
      # Only the account owner may merge checkout fields into an existing profile.
      raise account_invalid if signed_in_as_buyer? && !@account.update_attributes(account_hash.compact)
    else
      begin
        @account.save!
      rescue StandardError
        raise account_invalid
      end
    end
    raise BannedEmail if @event.organisation.banned_emails_a.include?(@account.email)
  end

  # Says which details are invalid, like a phone number without its country code
  def account_invalid
    messages = @account.errors.full_messages
    messages.empty? ? AccountInvalid.new : AccountInvalid.new("#{messages.to_sentence}.")
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
    @quote.ignore_dandelion_donation?
  end

  def create_order
    @order = Order.create!(
      event: @event,
      account: @account,
      currency: @quote.currency,
      organisation_revenue_share: @event.organisation_revenue_share,
      revenue_sharer: (@event.revenue_sharer_organisationship.account if @event.revenue_sharer_organisationship),
      opt_in_organisation: @opt_in_organisation,
      opt_in_facilitator: @opt_in_facilitator,
      answers: @answer_pairs,
      application_fee_paid_to_dandelion: !ignore_dandelion_donation? && !@event.revenue_sharer_organisationship && @event.donations_to_dandelion?,
      donation_via_modal: !ignore_dandelion_donation? && @donation_via_modal,
      cohost: @cohost,
      affiliate_type: @affiliate_type,
      affiliate_id: @affiliate_id,
      discount_code_id: @quote.discount_code&.id,
      hear_about: @hear_about,
      via: @via,
      http_referrer: @http_referrer,
      idempotency_key: @idempotency_key
    )
    # Not needed for the purchase, so looked up in the background, once the order has joined the account to its
    # organisations (whose local groups need the coordinates)
    @account.delay.geocode_location! if @account.skip_geocoding && @account.location
  rescue Mongo::Error::OperationFailure => e
    raise IdempotencyKeyTaken if @idempotency_key && e.code == 11_000

    raise
  end

  # What a booking takes from: the event's places; its discount code's uses, which an organisation's code shares across
  # its events; and the buyer's credit with the organisation, which they can spend on any of them. Always in this
  # order, so bookings holding some never wait on each other
  def booking_locks
    organisationship = @event.organisation.organisationships.find_by(account: @account) if signed_in_as_buyer?
    [@event, @chosen_discount_code, organisationship].compact
  end

  def create_tickets
    # Counted afresh, now that no other booking can be creating tickets
    @event.reset_ticket_counts
    # The prices chosen for range and pay-what-you-want ticket types, which Quote has checked
    prices = @quote.lines.to_h { |line| [line.key, line.chosen_price] }
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
      price = prices[ticket_type_id] if ticket_type.range || ticket_type.price.nil?
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

  # As the quote worked them out (Quote says in what order, and why)
  def apply_donation_and_discounts
    check_quote
    @order.donations.create!(event: @event, account: @account, amount: @quote.donation) if @quote.donation
    discounts = { credit_applied: @quote.credit_applied, fixed_discount_applied: @quote.fixed_discount_applied }.compact
    @order.set(discounts) if discounts.any?
    @order.set(original_description: @order.description)
  end

  def check_quote
    # Another order used up the code since the quote, so the order dropped it (Order's before_validation): refused as the
    # quote would refuse it now, as a fixed discount would otherwise still be applied
    if @quote.discount_code && @order.discount_code_id != @quote.discount_code.id
      @order.destroy
      raise DiscountCodeInvalid, "The discount code #{@quote.discount_code.code} has been used up."
    end

    return if @order.discounted_ticket_revenue == @quote.discounted_ticket_revenue &&
              @order.percentage_discount == @quote.percentage_discount &&
              @order.percentage_discount_monthly_donor == @quote.percentage_discount_monthly_donor

    raise QuoteMismatch, "Order #{@order.id}'s tickets came to #{@order.discounted_ticket_revenue.format}, not the quote's #{@quote.discounted_ticket_revenue.format}"
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
