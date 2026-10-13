module Dandelion
  module MCP
    # Unpaid orders are deleted by the hourly cleanup in tasks/tasks.rake
    ORDER_HOLD = 1.hour

    CHECKOUT_ARGS = %i[slug id quantities prices answers payment_method accept_terms phone hear_about opt_in_organisation opt_in_facilitator confirm_duplicate idempotency_key].freeze

    def self.perform_create_checkout(server_context: nil, slug: nil, id: nil, quantities: nil, prices: nil, answers: nil, payment_method: nil,
                                     accept_terms: false, phone: nil, hear_about: nil, opt_in_organisation: false, opt_in_facilitator: false,
                                     confirm_duplicate: false, idempotency_key: nil)
      with_account(server_context) do |account|
        next tool_error('Provide event slug or id') if slug.blank? && id.blank?

        event = Event.live.publicly_visible.find_by_slug_or_id(slug: slug, id: id)
        next tool_error('Event not found') unless event

        if idempotency_key.present? && (order = event.orders.find_by(account: account, idempotency_key: idempotency_key.to_s))
          next tool_json(order_status(order))
        end

        error = checkout_error(event, account, quantities: quantities, payment_method: payment_method, phone: phone, accept_terms: accept_terms)
        next tool_error(error) if error

        question_answers, error = checkout_answers(event, answers)
        next tool_error(error) if error

        builder = OrderBuilder.new(
          event: event,
          buyer: { name: account.name, email: account.email, phone: phone },
          signed_in_account: account,
          quantities: quantities.to_h.transform_keys(&:to_s),
          prices: prices.to_h.transform_keys(&:to_s),
          payment_method: payment_method || event_agent_payment_methods(event).first&.name || 'rsvp',
          answers: question_answers,
          opt_in_organisation: event.opt_in_organisation && opt_in_organisation == true,
          opt_in_facilitator: event.opt_in_facilitator && opt_in_facilitator == true,
          hear_about: (hear_about if event.ask_hear_about),
          via: 'mcp',
          confirmed_duplicate: confirm_duplicate == true
        )
        response = JSON.parse(builder.call)
        builder.order.set(idempotency_key: (idempotency_key.to_s if idempotency_key.present?), checkout_url: response['session_url'] || response['redirect_url'])
        tool_json(order_status(builder.order.reload))
      rescue OrderBuilder::Duplicate => e
        tool_error("#{e.message} If the buyer wants to book again, call this tool again with confirm_duplicate set to true.")
      rescue OrderBuilder::Error => e
        tool_error(checkout_error_message(e))
      end
    end

    def self.event_agent_payment_methods(event)
      EventPaymentMethod.all.select { |pm| pm.redirect && pm.process && pm.available?(event) }
    end

    def self.checkout_error(event, account, quantities:, payment_method:, phone:, accept_terms:)
      return 'This organisation does not take bookings from AI agents. Send the buyer to the event page to book.' if event.organisation.no_agent_bookings
      return 'Only monthly donors to this organisation can book this event.' if event.monthly_donors_only && !event.monthly_donor?(account)
      return 'Only members can book this event.' if event.activity && event.activity.privacy != 'open' && !event.activity_member?(account)
      return 'Provide quantities: an object mapping ticket type ids to the number of tickets.' unless quantities.is_a?(Hash) && quantities.values.any? { |quantity| quantity.to_i.positive? }
      if payment_method && payment_method.to_s != 'rsvp' && event_agent_payment_methods(event).none? { |pm| pm.name == payment_method.to_s }
        return 'That payment method is not available to agents for this event. Use one with agent_checkout true, or send the buyer to the event page.'
      end
      return 'Phone numbers must start with + and the country code.' if phone && !phone.to_s.strip.start_with?('+')

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

      pairs = fields.map do |field|
        value = answers[field[:index].to_s]
        value = case field[:type]
                when 'checkbox' then ('true' if value == true || value.to_s == 'true')
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

      [pairs, nil]
    end

    def self.checkout_error_message(error)
      case error
      when OrderBuilder::TicketTypeNotFound then 'Ticket type not found. Use the ticket type ids from get_event_checkout_requirements_tool.'
      when OrderBuilder::NotEnoughTickets then 'Not enough tickets left of that type.'
      when OrderBuilder::BannedEmail then 'This account cannot book this event.'
      else "Booking failed: #{error.message}"
      end
    end

    def self.order_status(order)
      event = order.event
      status = if order.deleted_at
                 'expired'
               elsif order.complete?
                 'complete'
               else
                 'awaiting_payment'
               end
      {
        order_id: order.id.to_s,
        status: status,
        event: { name: event.name, slug: event.slug, url: "#{ENV['BASE_URI']}/e/#{event.slug}", start_time: event.start_time },
        tickets: order.tickets.map { |ticket| { ticket_type: ticket.ticket_type&.name, price: ticket.discounted_price } },
        total: order.total,
        currency: order.currency,
        checkout_url: (order.checkout_url if status == 'awaiting_payment'),
        pay_by: (order.created_at + ORDER_HOLD if status == 'awaiting_payment'),
        created_at: order.created_at
      }
    end

    def self.perform_get_order_status(server_context: nil, order_id: nil)
      with_account(server_context) do |account|
        next tool_error('Provide order_id') if order_id.blank?

        order = Order.unscoped.find(order_id)
        next tool_error('Order not found') unless order && order.event
        next tool_error('Order not found') unless order.account_id == account.id || Event.admin?(order.event, account)

        tool_json(order_status(order))
      end
    end
  end
end
