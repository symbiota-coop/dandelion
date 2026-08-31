Dandelion::App.controller do
  post '/events/:id/purchase', provides: :json do
    @event = Event.find(params[:id]) || not_found
    halt 403 unless can_purchase_event_tickets?
    ticket_form = params[:ticketForm]
    details_form = params[:detailsForm]
    account_data = details_form[:account]
    account_hash = {
      name: account_data[:name],
      email: account_data[:email],
      postcode: account_data[:postcode],
      country: account_data[:country]
    }
    account_hash[:phone] = account_data[:phone] if @event.organisation.collect_phone?

    @account = Account.find_by(email: account_data[:email].downcase)
    @account ||= Account.new(account_hash.merge(skip_confirmation_email: true, default_currency: visitor_currency))

    if @account.persisted?
      # Only the account owner may merge checkout fields into an existing profile.
      if current_account && current_account.id == @account.id
        @account.update_attributes!(account_hash.map { |k, v| [k, v] if v }.compact.to_h)
      end
    else
      begin
        @account.save!
      rescue StandardError
        halt 400
      end
    end
    halt 403 if @event.organisation.banned_emails_a.include?(@account.email)

    @order = Order.create!(
      event: @event,
      account: @account,
      currency: EventPaymentMethod.object(details_form[:payment_method])&.order_currency_for(@event) || @event.currency,
      organisation_revenue_share: @event.organisation_revenue_share,
      revenue_sharer: (@event.revenue_sharer_organisationship.account if @event.revenue_sharer_organisationship),
      opt_in_organisation: account_data[:opt_in_organisation] == '1' || (account_data[:opt_in_organisation].is_a?(Array) && account_data[:opt_in_organisation].include?('1')),
      opt_in_facilitator: account_data[:opt_in_facilitator].is_a?(Array) && account_data[:opt_in_facilitator].include?('1'),
      answers: question_answer_pairs(details_form),
      application_fee_paid_to_dandelion: !ignore_dandelion_donation?(details_form) && !@event.revenue_sharer_organisationship && @event.donations_to_dandelion?,
      donation_via_modal: !ignore_dandelion_donation?(details_form) && ticket_form[:donation_via_modal].to_s == '1',
      cohost: ticket_form[:cohost],
      affiliate_type: ticket_form[:affiliate_type],
      affiliate_id: ticket_form[:affiliate_id],
      discount_code_id: ticket_form[:discount_code_id],
      hear_about: account_data[:hear_about],
      via: account_data[:via],
      http_referrer: account_data[:http_referrer]
    )

    ticket_form[:quantities].each do |ticket_type_id, quantity|
      next if quantity.to_i <= 0

      ticket_type = @event.ticket_types.find(ticket_type_id)
      unless ticket_type
        @order.destroy
        not_found
      end
      price = if ticket_type.range || ticket_type.price.nil?
                submitted_price = Float(ticket_form[:prices]&.[](ticket_type_id), exception: false) || 0
                ticket_type.range ? submitted_price.clamp(*ticket_type.range) : submitted_price
              end
      quantity.to_i.times do
        @order.tickets.create!(
          event: @event,
          account: @account,
          ticket_type: ticket_type,
          price: price
        )
      end
    end
    raise Order::NoTickets if @order.tickets.empty?

    @order.donations.create!(event: @event, account: @account, amount: ticket_form[:donation_amount]) if ticket_form[:donation_amount].to_f > 0 && !ignore_dandelion_donation?(details_form)

    @order.filter_discounts if @order.discount_code && @order.discount_code.filter
    @order.apply_credit if current_account
    @order.apply_fixed_discount
    @order.set(original_description: @order.description)

    pm = if @order.total > 0
           EventPaymentMethod.object(details_form[:payment_method].to_s)
         else
           EventPaymentMethod.object('rsvp')
         end
    raise Order::PaymentMethodNotFound if @order.total.positive? && pm&.name == 'rsvp'
    raise Order::PaymentMethodNotFound unless pm&.process
    raise Order::PaymentMethodNotFound unless pm&.available?(@event)

    pm.process_payment(order: @order, event: @event, account: @account, details_form: details_form, ticket_form: ticket_form)
  rescue Stripe::InvalidRequestError => e
    # Don't lock the event if the error is simply that the value is not high enough
    unless e.message&.include?('must add up to at least')
      @order.event.set(locked: true)
      @order.event.delete_atproto
    end
    @order.notify_of_failed_purchase(e)
    @order.destroy
    halt 400
  rescue GoCardlessPro::InvalidApiUsageError => e
    # Credential or permission issue on the organisation's GoCardless token (not an app bug)
    @order.event.set(locked: true)
    @order.event.delete_atproto
    @order.notify_of_failed_purchase(e, provider: 'GoCardless')
    @order.destroy
    halt 400
  rescue StandardError => e
    ctx = {}
    ctx[:order_id] = @order.id.to_s if @order
    ErrorReporting.capture_exception(e, context: ctx.presence)
    @order.try(:destroy)
    halt 400
  end
end
