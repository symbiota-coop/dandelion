module Dandelion
  module MCP
    # With an API key, books as that account. Without one, books as the buyer given, as the checkout form does for
    # someone signed out: finding the account with their email, or creating one
    def self.perform_create_checkout(server_context: nil, slug: nil, id: nil, quantities: nil, answers: nil, accept_terms: false, idempotency_key: nil, buyer: nil,
                                     opt_ins: nil)
      return tool_error('Provide event slug or id') if slug.blank? && id.blank?

      event = Event.live.publicly_visible.find_by_slug_or_id(slug: slug, id: id)
      return tool_error('Event not found') unless event

      signed_in_account = current_account_from(server_context)
      buyer = (buyer.is_a?(Hash) ? buyer : {}).transform_keys(&:to_sym).slice(:name, :email, :phone, :postcode, :country, :hear_about).transform_values(&:to_s)
      # How they heard about the event is the order's, so it's taken whoever the booking is for
      hear_about = buyer.delete(:hear_about)
      hear_about = nil if hear_about.blank? || !event.ask_hear_about
      buyer = { name: signed_in_account.name, email: signed_in_account.email } if signed_in_account
      return tool_error('Provide buyer: an object with the name and email of who the tickets are for, or authenticate with an API key to book as that account.') if buyer[:name].blank? || buyer[:email].blank?

      idempotency_key = (idempotency_key.to_s if idempotency_key.present?)
      if idempotency_key && (order = idempotent_order(event, signed_in_account, buyer, idempotency_key))
        return tool_json(order_status(order, details: signed_in_account.present?))
      end

      payment_method = event_agent_payment_methods(event).first
      error = checkout_error(event, quantities: quantities, accept_terms: accept_terms)
      return tool_error(error) if error

      question_answers, error = checkout_answers(event, answers)
      return tool_error(error) if error

      opt_ins, error = checkout_opt_ins(event, opt_ins)
      return tool_error(error) if error

      builder = OrderBuilder.new(
        event: event,
        buyer: buyer,
        signed_in_account: signed_in_account,
        quantities: quantities.to_h.transform_keys(&:to_s),
        # OrderBuilder pays with RSVP whenever nothing is left to pay
        payment_method: payment_method&.name || 'rsvp',
        answers: question_answers,
        opt_in_organisation: opt_ins.include?('opt_in_organisation'),
        opt_in_facilitator: opt_ins.include?('opt_in_facilitator'),
        hear_about: hear_about,
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

      tool_error('This account already has a ticket to this event. To book again, the buyer can use the event page.')
    rescue OrderBuilder::Error => e
      # OrderBuilder deletes a failed attempt's order: free its key, so that a retry books rather than finding it expired
      Order.unscoped.and(_id: builder.order.id).update_all('$unset' => { idempotency_key: 1 }) if builder&.order
      tool_error(checkout_error_message(e, payment_method: payment_method))
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

    # The checks for agent bookings only. OrderBuilder checks who may book and what's on sale
    def self.checkout_error(event, quantities:, accept_terms:)
      book_on_page = 'Send the buyer to the event page to book.'
      return 'Provide quantities: an object mapping ticket type ids to the number of tickets.' unless quantities.is_a?(Hash)

      ticket_types = quantities.select { |_ticket_type_id, quantity| quantity.to_i.positive? }.keys.map { |ticket_type_id| event.ticket_types.find(ticket_type_id.to_s) }
      if ticket_types.any? { |ticket_type| ticket_type && (ticket_type.range || ticket_type.price.nil?) }
        return "Agents can only book fixed-price tickets. #{book_on_page}"
      end

      'The buyer must accept the terms and conditions: show them the terms, then set accept_terms to true.' if event.terms_acceptance_required? && accept_terms != true
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

    # OrderBuilder's errors say what went wrong; this only adds what an agent can do about it. Whether there's anything
    # to pay is only known once OrderBuilder has applied credit and discounts
    def self.checkout_error_message(error, payment_method: nil)
      return "#{error.message} Use the ticket type ids from get_event_checkout_requirements_tool." if error.is_a?(OrderBuilder::TicketTypeNotFound)
      if error.is_a?(OrderBuilder::PaymentMethodUnavailable) && !payment_method
        return 'This event takes no payment methods agents can use. Send the buyer to the event page to book.'
      end
      # Agents don't choose an amount to give on the buyer's behalf
      return "#{error.message} Agents can't add donations: send the buyer to the event page to book." if error.is_a?(OrderBuilder::DonationRequired)

      error.message
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

      {
        order_id: order.id.to_s,
        status: status,
        event: { name: event.name, slug: event.slug, url: "#{ENV['BASE_URI']}/e/#{event.slug}", start_time: event.start_time },
        tickets: order.tickets.map { |ticket| { ticket_type: ticket.ticket_type&.name, price: ticket.discounted_price } },
        total: order.total,
        currency: order.currency,
        checkout_url: (order.checkout_url if status == 'awaiting_payment'),
        pay_by: (order.created_at + Order::UNPAID_HOLD if status == 'awaiting_payment'),
        created_at: order.created_at
      }
    end
  end
end
