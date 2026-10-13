# Books tickets to an event and hands the order to a payment method: the
# steps behind the checkout form (POST /events/:id/purchase), taking plain
# values so other callers, like agents, can book the same way.
#
# The caller decides whether the buyer may book (can_purchase_event_tickets?).
# Failures raise an OrderBuilder::Error, after destroying any order created.
class OrderBuilder
  class Error < StandardError
    def status
      400
    end
  end

  class AccountInvalid < Error; end

  class PaymentFailed < Error; end

  class BannedEmail < Error
    def status
      403
    end
  end

  class TicketTypeNotFound < Error
    def status
      404
    end
  end

  class NotEnoughTickets < Error; end

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
        @order.event.set(locked: true)
        @order.event.delete_atproto
      end
      @order.notify_of_failed_purchase(e, provider: info[:provider], help: info[:help])
      @order.destroy
      raise PaymentFailed, e.message
    end

    ErrorReporting.capture_exception(e, context: ({ order_id: @order.id.to_s } if @order))
    @order.try(:destroy)
    raise Error, e.message
  end

  private

  def find_or_create_account
    account_hash = @buyer.slice(:name, :email, :postcode, :country)
    account_hash[:phone] = @buyer[:phone] if @event.organisation.collect_phone?

    @account = Account.find_by(email: @buyer[:email].downcase.strip)
    @account ||= Account.new(account_hash.merge(skip_confirmation_email: true, default_currency: @new_account_currency))

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
    raise Order::NoTickets if @order.tickets.empty?
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
    raise Order::PaymentMethodNotFound if @order.total.positive? && pm&.name == 'rsvp'
    raise Order::PaymentMethodNotFound unless pm&.process
    raise Order::PaymentMethodNotFound unless pm&.available?(@event)

    pm.process_payment(order: @order, event: @event, account: @account, cohost: @cohost, utm: @utm)
  end
end
