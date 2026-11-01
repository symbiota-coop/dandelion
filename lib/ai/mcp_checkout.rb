module Dandelion
  module MCP
    # Where the buyer came from, as the event page's query string passes it to the checkout form
    CHECKOUT_ATTRIBUTION_FIELDS = %w[cohost affiliate_type affiliate_id utm_source utm_medium utm_campaign].freeze

    # With an API key, books as that account. Without one, books as the buyer given, as the checkout form does for
    # someone signed out: finding the account with their email, or creating one
    def self.perform_create_checkout(server_context: nil, slug: nil, id: nil, quantities: nil, prices: nil, answers: nil, accept_terms: false, idempotency_key: nil,
                                     buyer: nil, opt_ins: nil, discount_code: nil, payment_method: nil, secret_ticket_type_id: nil, donation_amount: nil,
                                     confirm_duplicate: false, attribution: nil)
      return tool_error('Provide event slug or id') if slug.blank? && id.blank?

      event = Event.live.publicly_visible.find_by_slug_or_id(slug: slug, id: id)
      return tool_error('Event not found') unless event

      signed_in_account = current_account_from(server_context)
      buyer = checkout_buyer(event, buyer)
      # How they heard about the event is the order's, so it's taken whoever the booking is for
      hear_about = buyer.delete(:hear_about)
      # With an API key the booking is that account's, and the other details update its profile, as the checkout form
      # updates the signed-in account's
      buyer = buyer.merge(name: signed_in_account.name, email: signed_in_account.email) if signed_in_account
      return tool_error('Provide buyer: an object with the name and email of who the tickets are for, or authenticate with an API key to book as that account.') if buyer[:name].blank? || buyer[:email].blank?

      idempotency_key = (idempotency_key.to_s if idempotency_key.present?)
      if idempotency_key && (order = idempotent_order(event, signed_in_account, buyer, idempotency_key))
        return tool_json(order_status(order, details: signed_in_account.present?))
      end

      return tool_error('Provide quantities: an object mapping ticket type ids to the number of tickets.') unless quantities.is_a?(Hash)

      quantities = quantities.transform_keys(&:to_s)
      secret_ticket_type_id = secret_ticket_type_id_from(secret_ticket_type_id)
      if secret_ticket_type_id && !event.secret_ticket_type(secret_ticket_type_id)
        return tool_error("That secret link doesn't unlock a ticket type of this event. Check the link with the buyer.")
      end

      ticket_types = quantities.select { |_ticket_type_id, quantity| quantity.to_i.positive? }.keys.filter_map { |ticket_type_id| event.ticket_types.find(ticket_type_id) }

      discount_code, error = checkout_discount_code(event, discount_code, ticket_types)
      return tool_error(error) if error

      prices, error = checkout_prices(event, ticket_types, prices)
      return tool_error(error) if error

      donation_amount, error = checkout_donation_amount(event, donation_amount)
      return tool_error(error) if error

      if event.terms_acceptance_required? && accept_terms != true
        return tool_error('The buyer must accept the terms and conditions: show them the terms, then set accept_terms to true.')
      end

      question_answers, error = checkout_answers(event, answers)
      return tool_error(error) if error

      opt_ins, error = checkout_opt_ins(event, opt_ins)
      return tool_error(error) if error

      attribution = checkout_attribution(attribution)
      # The event page with the buyer's choices filled in, for when they need to finish booking there
      page_url = checkout_page_url(event, quantities: quantities, prices: prices, discount_code: discount_code, secret_ticket_type_id: secret_ticket_type_id,
                                          donation_amount: donation_amount, attribution: attribution)

      payment_method, error = checkout_payment_method(event, payment_method, page_url: page_url)
      return tool_error(error) if error

      builder = OrderBuilder.new(
        event: event,
        buyer: buyer,
        signed_in_account: signed_in_account,
        quantities: quantities,
        prices: prices,
        secret_ticket_type_id: secret_ticket_type_id,
        # OrderBuilder pays with RSVP whenever nothing is left to pay
        payment_method: payment_method&.name || 'rsvp',
        answers: question_answers,
        donation_amount: donation_amount,
        discount_code_id: discount_code&.id,
        cohost: attribution['cohost'],
        affiliate_type: attribution['affiliate_type'],
        affiliate_id: attribution['affiliate_id'],
        utm: { source: attribution['utm_source'], medium: attribution['utm_medium'], campaign: attribution['utm_campaign'] },
        opt_in_organisation: opt_ins.include?('opt_in_organisation'),
        opt_in_facilitator: opt_ins.include?('opt_in_facilitator'),
        hear_about: hear_about,
        confirmed_duplicate: confirm_duplicate == true,
        via: 'mcp',
        idempotency_key: idempotency_key
      )
      response = JSON.parse(builder.call)
      builder.order.set(checkout_url: response['session_url'] || response['redirect_url'])
      tool_json(order_status(builder.order.reload))
    rescue OrderBuilder::IdempotencyKeyTaken
      # The other request's order can be gone already, if it failed and freed the key
      order = idempotent_order(event, signed_in_account, buyer, idempotency_key)
      return tool_json(order_status(order, details: signed_in_account.present?)) if order

      tool_error(OrderBuilder::Error.new.message)
    rescue OrderBuilder::Duplicate
      # A retry at the same time as a free booking finds its ticket before its order
      if idempotency_key && (order = idempotent_order(event, signed_in_account, buyer, idempotency_key))
        return tool_json(order_status(order, details: signed_in_account.present?))
      end

      tool_error('This account already has a ticket to this event. If the buyer wants to book again, check with them, then call create_checkout_tool again with confirm_duplicate set to true.')
    rescue OrderBuilder::Error => e
      # OrderBuilder deletes a failed attempt's order: free its key, so that a retry books rather than finding it expired
      Order.unscoped.and(_id: builder.order.id).update_all('$unset' => { idempotency_key: 1 }) if builder&.order
      tool_error(checkout_error_message(e, event: event, payment_method: payment_method, page_url: page_url))
    end

    # The order an earlier call with this key made, including one deleted once it went unpaid (which a late payment
    # can still restore), so a retry reports it rather than booking again
    def self.idempotent_order(event, signed_in_account, buyer, idempotency_key)
      account = signed_in_account || Account.find_by(email: buyer[:email].downcase.strip)
      return unless account

      Order.unscoped.find_by(event_id: event.id, account_id: account.id, idempotency_key: idempotency_key)
    end

    # Payment methods where paying means following a link, so the buyer can pay at the checkout_url
    def self.event_agent_payment_methods(event)
      EventPaymentMethod.all.select { |pm| pm.redirect && pm.process && pm.available?(event) }
    end

    # The buyer details the event asks for, from buyer_fields, without blanks (as the checkout form's are nil)
    def self.checkout_buyer(event, buyer)
      fields = event.checkout_buyer_fields.map { |field| field[:name].to_sym }
      (buyer.is_a?(Hash) ? buyer : {}).transform_keys(&:to_sym).slice(*fields).transform_values { |value| value.to_s.strip }.reject { |_field, value| value.empty? }
    end

    # The ticket_type_id of a hidden ticket type's secret link: the id itself, or the link
    # (https://dandelion.events/e/slug?ticket_type_id=...)
    def self.secret_ticket_type_id_from(value)
      value = value.to_s.strip
      return if value.empty?
      return value unless value.include?('?')

      # A link without one unlocks nothing
      Rack::Utils.parse_query(value.split('?', 2).last.split('#').first)['ticket_type_id'] || ''
    end

    # The payment method the buyer chose, or the first one agents can use. RSVP and the like are only for when nothing
    # is left to pay, which OrderBuilder works out
    def self.checkout_payment_method(event, name, page_url:)
      choices = event_agent_payment_methods(event)
      return [choices.first, nil] if name.blank?

      free_only = EventPaymentMethod.all.select { |pm| pm.complimentary && pm.process && pm.available?(event) }
      chosen = (choices + free_only).detect { |pm| pm.name == name.to_s }
      return [chosen, nil] if chosen
      return [nil, "This event takes no payment methods agents can use. Send the buyer to #{page_url} to book."] if choices.empty?

      [nil, "Choose one of the payment methods agents can use for this event: #{choices.map(&:name).join(', ')}."]
    end

    # The discount code the buyer entered, which must apply to each ticket they chose, as the checkout form only shows
    # those ticket types once the code is applied
    def self.checkout_discount_code(event, code, ticket_types)
      return [nil, nil] if code.to_s.strip.empty?

      discount_code, problem = event.checkout_discount_code(code)
      return [nil, "The discount code #{code} has been used up."] if problem == :used_up
      return [nil, "The discount code #{code} is not valid for this event."] unless discount_code

      unless ticket_types.all? { |ticket_type| discount_code.applies_to_ticket_type?(ticket_type) }
        return [nil, "The discount code #{code} only applies to ticket types whose names include #{discount_code.filters.join(' or ')}."]
      end

      [discount_code, nil]
    end

    # prices: the price per ticket the buyer chose for each range or pay-what-you-want ticket type, keyed by ticket type
    # id. Agents don't choose an amount on the buyer's behalf, so each needs one, within the ticket type's range
    def self.checkout_prices(event, ticket_types, prices)
      prices = prices.is_a?(Hash) ? prices.transform_keys(&:to_s) : {}
      chosen = {}
      problems = ticket_types.uniq.filter_map do |ticket_type|
        next unless ticket_type.range || ticket_type.price.nil?

        price = Float(prices[ticket_type.id.to_s], exception: false)
        bounds = if ticket_type.range
                   "from #{format_money(ticket_type.range_min, event.currency)} to #{format_money(ticket_type.range_max, event.currency)}"
                 else
                   "#{format_money(0, event.currency)} or more"
                 end
        if price.nil? || (ticket_type.range ? !price.between?(*ticket_type.range) : price.negative?)
          "#{ticket_type.name} (#{bounds})"
        else
          chosen[ticket_type.id.to_s] = price
          nil
        end
      end
      if problems.any?
        return [nil, "Ask the buyer how much they want to pay per ticket, and pass it in prices, keyed by ticket type id: #{problems.join('; ')}"]
      end

      [chosen, nil]
    end

    # A donation the buyer chose to add, where the checkout form offers one. OrderBuilder checks any minimum
    def self.checkout_donation_amount(event, amount)
      return [nil, nil] if amount.to_s.strip.empty?

      amount = Float(amount, exception: false)
      return [nil, 'donation_amount must be a number, 0 or more.'] if amount.nil? || amount.negative?
      return [nil, "This event doesn't take donations at checkout."] if amount.positive? && !event.checkout_donation

      [amount, nil]
    end

    # answers: an object mapping question indexes (from get_event_checkout_requirements_tool)
    # to strings, true/false for a checkbox, or an array of options for checkboxes.
    # Returns the [question, answer] pairs the checkout form would, or an error.
    def self.checkout_answers(event, answers)
      answers = (answers || {}).to_h.transform_keys(&:to_s)
      fields = Questions.parse(event.questions).reject { |field| %w[heading info].include?(field[:type]) }
      unknown = answers.keys - fields.map { |field| field[:index].to_s }
      return [nil, "Unknown question indexes: #{unknown.join(', ')}"] if unknown.any?

      invalid = fields.select do |field|
        answer = answers[field[:index].to_s].to_s.strip
        field[:type] == 'select' && !answer.empty? && !field[:options].include?(answer)
      end
      return [nil, "Choose one of the options: #{invalid.map { |field| "#{field[:text]} (#{field[:options].join(', ')})" }.join('; ')}"] if invalid.any?

      # Stored as the checkout form sends them: a ticked checkbox as '1', and an unticked one not at all
      pairs = fields.map do |field|
        value = answers[field[:index].to_s]
        value = case field[:type]
                when 'checkbox' then ('1' if value == true || value.to_s == 'true')
                when 'checkboxes'
                  selected = Array(value).map(&:to_s) & field[:options]
                  selected unless selected.empty?
                else
                  value.to_s.strip unless value.to_s.strip.empty?
                end
        [field[:question], value]
      end

      missing = fields.zip(pairs).select { |field, (_question, value)| field[:required] && value.nil? }.map { |field, _pair| field[:text] }
      return [nil, "Answer the required questions: #{missing.join('; ')}"] if missing.any?

      [fields.zip(pairs).reject { |field, (_question, value)| field[:type] == 'checkbox' && value.nil? }.map(&:last), nil]
    end

    # opt_ins: the names of the opt-ins get_event_checkout_requirements_tool lists that the buyer chose
    def self.checkout_opt_ins(event, opt_ins)
      opt_ins = Array(opt_ins).map(&:to_s)
      offered = event.checkout_opt_ins.map { |opt_in| opt_in[:name] }
      unknown = opt_ins - offered
      return [nil, "This event doesn't offer these opt-ins: #{unknown.join(', ')}"] if unknown.any?

      [opt_ins, nil]
    end

    # attribution: the cohost, affiliate and UTM values from the query string of the event link the buyer followed
    def self.checkout_attribution(attribution)
      attribution = attribution.is_a?(Hash) ? attribution.transform_keys(&:to_s) : {}
      attribution.slice(*CHECKOUT_ATTRIBUTION_FIELDS).transform_values { |value| value.to_s.strip }.reject { |_field, value| value.empty? }
    end

    # The event page's checkout form, filled in with the buyer's choices as its query string fills it in
    def self.checkout_page_url(event, quantities:, prices:, discount_code:, secret_ticket_type_id:, donation_amount:, attribution:)
      query = {
        'ticket_type_id' => secret_ticket_type_id,
        'discount_code' => discount_code&.code,
        'quantities' => quantities.select { |_ticket_type_id, quantity| quantity.to_i.positive? }.transform_values(&:to_i),
        'prices' => prices,
        'donation_amount' => donation_amount
      }.merge(attribution).reject { |_key, value| value.nil? || (value.respond_to?(:empty?) && value.empty?) }
      "#{ENV['BASE_URI']}/e/#{event.slug}#{"?#{Rack::Utils.build_nested_query(query)}" unless query.empty?}#select-tickets"
    end

    def self.format_money(amount, currency)
      Money.new((amount * 100).round, currency).format(no_cents_if_whole: true)
    end

    # OrderBuilder's errors say what went wrong; this only adds what an agent can do about it. Whether there's anything
    # to pay is only known once OrderBuilder has applied credit and discounts
    def self.checkout_error_message(error, event:, payment_method: nil, page_url: nil)
      case error
      when OrderBuilder::TicketTypeNotFound
        "#{error.message} Use the ticket type ids from get_event_checkout_requirements_tool (hidden ones need their secret_ticket_type_id)."
      when OrderBuilder::PaymentMethodUnavailable
        if !payment_method
          "This event takes no payment methods agents can use. Send the buyer to #{page_url} to book."
        elsif payment_method.complimentary
          choices = event_agent_payment_methods(event).map(&:name)
          "#{payment_method.name} is only for bookings with nothing left to pay. #{choices.any? ? "Choose one of: #{choices.join(', ')}." : "Send the buyer to #{page_url} to book."}"
        else
          error.message
        end
      when OrderBuilder::DonationRequired
        # Agents don't choose an amount to give on the buyer's behalf
        "#{error.message} Ask the buyer how much they want to give, and pass it as donation_amount."
      when OrderBuilder::NotAllowed
        "#{error.message} If the buyer can book it, they can book with their own API key, or signed in at #{page_url}"
      else
        error.message
      end
    end

    # details: false for a retry without an API key, which only proves the caller knows the buyer's email and the key:
    # the first call already had the order's details and checkout_url
    def self.order_status(order, details: true)
      event = order.event
      # An order is saved with its key before its tickets and payment are set up, so a retry can find it part made
      status = if order.deleted_at
                 'expired'
               elsif order.complete?
                 'complete'
               elsif order.checkout_url
                 'awaiting_payment'
               else
                 'processing'
               end
      # Neither has its tickets yet, or still: the cleanup deletes an expired order's tickets with it
      case status
      when 'processing'
        return { order_id: order.id.to_s, status: status,
                 message: 'This booking is still being set up. Call create_checkout_tool again with the same idempotency_key in a few seconds.' }
      when 'expired'
        return { order_id: order.id.to_s, status: status,
                 message: 'This booking expired before it was paid for. To book again, call create_checkout_tool with a new idempotency_key.' }
      end
      unless details
        return { order_id: order.id.to_s, status: status,
                 message: 'This idempotency_key was already used for this booking. Its details, and any checkout_url, went to the call that made it.' }
      end

      donation = order.donation_revenue.cents.to_f / 100
      {
        order_id: order.id.to_s,
        status: status,
        event: { name: event.name, slug: event.slug, url: "#{ENV['BASE_URI']}/e/#{event.slug}", start_time: event.start_time },
        tickets: order.tickets.map { |ticket| { ticket_type: ticket.ticket_type&.name, price: ticket.discounted_price } },
        donation: (donation if donation.positive?),
        discounts: {
          discount_code: order.discount_code&.code,
          percentage_discount: order.percentage_discount,
          membership_percentage_discount: order.percentage_discount_monthly_donor,
          fixed_discount: order.fixed_discount_applied,
          credit: order.credit_applied
        }.compact,
        total: order.total,
        currency: order.currency,
        checkout_url: (order.checkout_url if status == 'awaiting_payment'),
        pay_by: (order.created_at + Order::UNPAID_HOLD if status == 'awaiting_payment'),
        created_at: order.created_at
      }
    end

    # Joins a sold-out ticket type's waitlist, or the event's own once it's sold out, as the event page does: as the API
    # key's account, or without one as the buyer given, finding the account with their email or creating one
    def self.perform_join_waitlist(server_context: nil, slug: nil, id: nil, ticket_type_id: nil, buyer: nil)
      return tool_error('Provide event slug or id') if slug.blank? && id.blank?

      event = Event.live.publicly_visible.find_by_slug_or_id(slug: slug, id: id)
      return tool_error('Event not found') unless event

      if ticket_type_id.present?
        ticket_type = event.ticket_types.find(ticket_type_id.to_s)
        return tool_error('Ticket type not found. Use the ticket type ids from get_event_checkout_requirements_tool.') unless ticket_type

        # Whether the waitlist is open doesn't depend on who joins it, so it's checked before finding or creating an account
        eligibility = TicketTypeWaitship.new(ticket_type: ticket_type)
        eligibility.valid?
        return tool_error(eligibility.errors[:base].first) if eligibility.errors[:base].any?
      else
        error = event_waitlist_error(event)
        return tool_error(error) if error
      end

      account = current_account_from(server_context)
      unless account
        buyer = (buyer.is_a?(Hash) ? buyer : {}).transform_keys(&:to_sym).slice(:name, :email).transform_values { |value| value.to_s.strip }
        return tool_error('Provide buyer: an object with the name and email of who is joining the waitlist, or authenticate with an API key to join as that account.') if buyer[:name].blank? || buyer[:email].blank?

        account = Account.find_by(email: buyer[:email].downcase) || Account.new(name: buyer[:name], email: buyer[:email], password: Account.generate_password)
        return tool_error("#{account.errors.full_messages.to_sentence}.") unless account.persisted? || account.save
      end

      waitship = if ticket_type
                   ticket_type.ticket_type_waitships.find_by(account: account) || TicketTypeWaitship.create(ticket_type: ticket_type, account: account)
                 else
                   event.waitships.find_by(account: account) || event.waitships.create(account: account)
                 end
      return tool_error("#{waitship.errors.full_messages.to_sentence}.") unless waitship.persisted?

      tool_json(
        status: 'joined',
        event: { name: event.name, slug: event.slug, url: "#{ENV['BASE_URI']}/e/#{event.slug}" },
        ticket_type: ticket_type&.name,
        message: "They'll get an email when tickets become available#{" to #{event.name} or the organiser's future events" unless ticket_type}."
      )
    end

    # Why the event's own waitlist can't be joined, if it can't. The event page offers it once the event is sold out,
    # unless the event has turned it off or its ticket types have waitlists of their own
    def self.event_waitlist_error(event)
      if event.ticket_type_waitlists_available?
        'This event has a waitlist for each sold-out ticket type: pass the ticket_type_id of one.'
      elsif !event.sold_out?
        "This event isn't sold out: book with create_checkout_tool."
      elsif event.hide_waitlist
        "This event doesn't have a waitlist."
      end
    end
  end
end
