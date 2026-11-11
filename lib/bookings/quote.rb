# What a booking costs, worked out without writing anything: the checkout form shows it (POST /e/:slug/quote) as the
# buyer chooses, and OrderBuilder takes the order's credit, fixed discount and donation from it, so the form shows what
# the order will be.
#
# The order of the steps: percentage discounts (a discount code's, or else a monthly donor's) come off each ticket
# (Ticket.discounted_price). Where donations go to Dandelion, a donation is our fee, not the organisation's revenue, so
# credit and a fixed discount pay only for the tickets: they're applied first, and the donation is added to what's left,
# unless they paid for the tickets in full, as those complete without a payment, which a donation to Dandelion needs.
# Otherwise the donation is added first, and credit and a fixed discount pay for it too. Each is capped at what's left
# to pay.
#
# validate! raises the OrderBuilder errors for what the checkout form wouldn't let the buyer choose. The amounts are
# worked out once, on first use, so a quote read before its order is created stays as it was (the order counts as a
# use of its discount code)
class Quote
  # key: the ticket type id as given (the checkout form's quantities key). price: the price per ticket before
  # discounts, the one chosen for range and pay-what-you-want ticket types. chosen_price: that chosen price, or nil
  Line = Struct.new(:key, :ticket_type, :quantity, :price, :chosen_price)

  attr_reader :event, :account

  # The quantities as given, keeping only numbers, as the form's selects give: anything else (a nested hash, say), as
  # only a crafted request sends, counts as none
  def self.quantities_from(quantities)
    (quantities.is_a?(Hash) ? quantities : {}).select { |_key, quantity| quantity.is_a?(String) || quantity.is_a?(Integer) }
  end

  # quantities and prices: keyed by ticket type id, as the checkout form sends them
  # account: the buyer's, for a monthly donor's discount and their credit, or nil
  # credit: whether to apply account's credit, only theirs to spend when they're signed in
  # discount_code: the code the buyer applied
  # payment_method: the name of the payment method, which sets the order's currency and, where donations go to
  # Dandelion, whether it takes one. nil for any, as the checkout form shows before one is chosen
  # secret_ticket_type_id: the public_id in a hidden ticket type's secret link
  # default_dandelion_donation: without a donation_amount, add the smallest donation to Dandelion there can be
  # (Event#default_dandelion_donation)
  def initialize(event:, quantities:, prices: {}, account: nil, credit: false, discount_code: nil, donation_amount: nil,
                 payment_method: nil, secret_ticket_type_id: nil, default_dandelion_donation: false)
    @event = event
    @quantities = self.class.quantities_from(quantities)
    @prices = prices.is_a?(Hash) ? prices : {}
    @account = account
    @credit = credit
    @discount_code_text = discount_code.to_s.strip
    @donation_amount = donation_amount
    @payment_method = payment_method
    @secret_ticket_type_id = secret_ticket_type_id
    @default_dandelion_donation = default_dandelion_donation
  end

  # The ticket types chosen, keyed as quantities are, leaving out those that aren't the event's
  def lines
    @lines ||= @quantities.filter_map do |key, quantity|
      quantity = quantity.to_i
      next unless quantity.positive?

      ticket_type = @event.ticket_types.find(key)
      next unless ticket_type

      chosen_price = Float(@prices[key], exception: false) if variable_price?(ticket_type)
      # Too big to be a price (1e400 is Infinity), so not chosen
      chosen_price = nil unless chosen_price&.finite?
      Line.new(key, ticket_type, quantity, variable_price?(ticket_type) ? chosen_price : ticket_type.price, chosen_price)
    end
  end

  def validate!
    check_ticket_types
    check_prices
    check_discount_code
    check_donation
    self
  end

  def currency
    @currency ||= payment_method_object&.order_currency_for(@event) || @event.currency
  end

  # [discount_code, nil], or [nil, :invalid] or [nil, :used_up] (Event#checkout_discount_code)
  def discount_code_and_problem
    @discount_code_and_problem ||= @discount_code_text.empty? ? [nil, nil] : @event.checkout_discount_code(@discount_code_text)
  end

  def discount_code
    discount_code_and_problem.first
  end

  def percentage_discount
    compute
    @percentage_discount
  end

  def percentage_discount_monthly_donor
    compute
    @percentage_discount_monthly_donor
  end

  # Money: the tickets after percentage discounts, as Order#discounted_ticket_revenue adds them up
  def discounted_ticket_revenue
    compute
    @discounted_ticket_revenue
  end

  # As Order's: nil when not applied, and otherwise what came off, which can be 0
  def credit_applied
    compute
    @credit_applied
  end

  def fixed_discount_applied
    compute
    @fixed_discount_applied
  end

  # The donation the order is charged, or nil
  def donation
    compute
    @donation
  end

  # Money, as Order#donation_revenue
  def donation_revenue
    Money.new((donation || 0) * 100, currency)
  end

  # Tickets and donation, before credit and a fixed discount: the checkout form's Total
  def subtotal
    (discounted_ticket_revenue + donation_revenue).cents.to_f / 100
  end

  # What the payment method is asked for, as Order#total
  def total
    subtotal - (credit_applied || 0) - (fixed_discount_applied || 0)
  end

  def payment_required?
    total.positive?
  end

  # Whether a payment method that can't take a donation to Dandelion is asked for anything: the order drops the
  # donation, so whether credit and a fixed discount paid for the tickets
  def payment_required_without_donation?
    @event.donations_to_dandelion? ? ticket_balance.positive? : payment_required?
  end

  def as_json(*)
    {
      currency: currency,
      tickets: discounted_ticket_revenue.cents.to_f / 100,
      percentage_discount: percentage_discount,
      percentage_discount_monthly_donor: percentage_discount_monthly_donor,
      credit_applied: credit_applied,
      fixed_discount_applied: fixed_discount_applied,
      donation: donation,
      subtotal: subtotal,
      total: total,
      payment_required: payment_required?,
      payment_required_without_donation: payment_required_without_donation?
    }
  end

  def to_json(*)
    as_json.to_json
  end

  # Where donations go to Dandelion, a payment method that can't take one drops it
  def ignore_dandelion_donation?
    !@payment_method.nil? && @event.donations_to_dandelion? && !payment_method_object&.platform_donations
  end

  private

  def variable_price?(ticket_type)
    ticket_type.range || ticket_type.price.nil?
  end

  def payment_method_object
    EventPaymentMethod.object(@payment_method.to_s) unless @payment_method.nil?
  end

  def compute
    return if @computed

    @computed = true
    @percentage_discount = discount_code&.percentage_discount
    @percentage_discount_monthly_donor = @event.monthly_donor_discount(@account) unless @percentage_discount
    @discounted_ticket_revenue = lines.sum(Money.new(0, currency)) do |line|
      discounted_price = Ticket.discounted_price(line.price, @percentage_discount, @percentage_discount_monthly_donor)
      Money.new((discounted_price || 0) * 100, currency) * line.quantity
    end
    amount = @donation_amount
    if @event.donations_to_dandelion?
      apply_credit_and_fixed_discount
      # Without a donation_amount, the smallest donation to Dandelion, once what's left of the tickets' price is known
      amount = @event.default_dandelion_donation(ticket_balance) if @default_dandelion_donation && amount.nil?
      tickets_paid_for = @discounted_ticket_revenue.positive? && ticket_balance <= 0
      @donation = donation_from(amount) unless tickets_paid_for
    else
      @donation = donation_from(amount)
      apply_credit_and_fixed_discount
    end
  end

  def donation_from(amount)
    amount.to_f.round(2) if amount.to_f.positive? && !ignore_dandelion_donation?
  end

  # The tickets less credit and a fixed discount, before any donation to Dandelion
  def ticket_balance
    compute
    (@discounted_ticket_revenue.cents.to_f / 100) - (@credit_applied || 0) - (@fixed_discount_applied || 0)
  end

  def running_total
    money = ->(amount) { Money.new((amount || 0) * 100, currency) }
    @discounted_ticket_revenue + money.(@donation) - money.(@credit_applied) - money.(@fixed_discount_applied)
  end

  def apply_credit_and_fixed_discount
    apply_credit if @credit && @account
    apply_fixed_discount
  end

  def apply_credit
    return unless (organisationship = @event.organisation.organisationships.find_by(account: @account))

    begin
      credit_balance = organisationship.credit_balance.exchange_to(currency)
    rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
      return
    end
    return unless credit_balance.positive?

    @credit_applied = [credit_balance, running_total].min.cents.to_f / 100
  end

  def apply_fixed_discount
    return unless discount_code&.fixed_discount

    @fixed_discount_applied = [discount_code.fixed_discount.exchange_to(currency), running_total].min.cents.to_f / 100
  end

  # Hidden ticket types can only be bought through their secret link
  def check_ticket_types
    @quantities.each do |key, quantity|
      next unless quantity.to_i.positive?

      ticket_type = @event.ticket_types.find(key)
      raise OrderBuilder::TicketTypeNotFound if !ticket_type || (ticket_type.hidden && @secret_ticket_type_id != ticket_type.public_id)
      raise OrderBuilder::SalesEnded if ticket_type.sales_ended? || @event.sales_closed_due_to_event_end?
    end
  end

  # Each range or pay-what-you-want ticket type needs a price, within its range: the checkout form only lets the buyer
  # choose one once they've set it
  def check_prices
    problems = lines.filter_map do |line|
      ticket_type = line.ticket_type
      next unless variable_price?(ticket_type)

      price = line.chosen_price
      next unless price.nil? || (ticket_type.range ? !price.between?(*ticket_type.range) : price.negative?)

      bounds = if ticket_type.range
                 "from #{format_money(ticket_type.range_min)} to #{format_money(ticket_type.range_max)}"
               else
                 "#{format_money(0)} or more"
               end
      "#{ticket_type.name} (#{bounds})"
    end.uniq
    raise OrderBuilder::PriceInvalid, "Choose a price per ticket for #{problems.join('; ')}." if problems.any?
  end

  # The code must be the event's and not used up, and apply to each ticket chosen: the checkout form only shows the
  # ticket types it applies to once it's applied
  def check_discount_code
    return if @discount_code_text.empty?

    discount_code, problem = discount_code_and_problem
    code = @discount_code_text.upcase
    raise OrderBuilder::DiscountCodeInvalid, "The discount code #{code} has been used up." if problem == :used_up
    raise OrderBuilder::DiscountCodeInvalid, "The discount code #{code} is not valid for this event." unless discount_code
    return if lines.all? { |line| discount_code.applies_to_ticket_type?(line.ticket_type) }

    raise OrderBuilder::DiscountCodeInvalid, "The discount code #{code} only applies to ticket types whose names include #{discount_code.filters.join(' or ')}."
  end

  def check_donation
    amount = @donation_amount.to_f
    donation = @event.checkout_donation
    raise OrderBuilder::DonationInvalid if amount.negative? || (amount.positive? && !donation)
    # Donation's own validation only sees a donation that's made
    raise OrderBuilder::DonationRequired.new(@event.minimum_donation, @event.currency) if donation_below_minimum?
    # Unless the payment method drops it, as it does a donation to Dandelion when it can't take one
    return unless donation && donation[:to] == 'dandelion' && donation[:minimum] && amount.positive? && !ignore_dandelion_donation?

    raise OrderBuilder::DonationTooSmall.new(donation[:minimum], @event.currency) if amount < donation[:minimum]
  end

  def donation_below_minimum?
    @event.minimum_donation&.positive? && !@event.donations_to_dandelion? && @donation_amount.to_f < @event.minimum_donation
  end

  def format_money(amount)
    Money.new((amount * 100).round, @event.currency).format(no_cents_if_whole: true)
  end
end
