Dandelion::App.controller do
  get '/orders/:id', provides: %i[html pdf ics] do
    @order = Order.complete.find_by_id_or_token(params[:id]) || not_found
    @event = @order.event
    account = @order.account || not_found
    headers['Referrer-Policy'] = 'no-referrer'

    case content_type
    when :html
      email_html_csp!
      @title = "Order confirmation for #{@event.name}"
      header_image_url, = @order.sender_info

      tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: account)
      EmailHelper.html(:tickets, event: @event, order: @order, account: account, tickets_table: tickets_table, header_image_url: header_image_url, viewing_on_web: true) do |content|
        content.gsub('%recipient.token%', '')
      end

    when :ics
      (cal = @event.ical(order: @order)) ? cal.to_ical : not_found
    when :pdf
      @order.tickets_pdf.render
    end
  end

  post '/e/:slug/purchase', provides: :json do
    @event = Event.find_by_slug_or_id(slug: params[:slug]) || not_found
    builder = OrderBuilder.new(**order_builder_args)
    result = JSON.parse(builder.call)
    # Whether the order waits for a payment: without one (RSVPs, and tickets credit or a fixed discount paid for), the
    # form goes straight to its confirmation
    result.merge(payment_required: builder.quote.payment_required?).to_json
  rescue OrderBuilder::Duplicate => e
    halt 409, { duplicate: true, error: e.message }.to_json
  rescue OrderBuilder::EmailLooksMistyped => e
    halt 409, { mistyped_email: true, error: e.message }.to_json
  rescue OrderBuilder::Error => e
    # Its message says what went wrong, for the buyer: the form shows it
    halt e.status, { error: e.message }.to_json
  end

  # What the checkout form's choices cost (Quote), which the form shows as the buyer chooses. It takes the ticket form's
  # fields as the purchase does, and refuses what the purchase would refuse of them
  post '/e/:slug/quote', provides: :json do
    @event = Event.find_by_slug_or_id(slug: params[:slug]) || not_found
    restriction = @event.booking_restriction(current_account)
    raise OrderBuilder::NotAllowed.new(restriction) if restriction

    ticket_form = params[:ticketForm].is_a?(Hash) ? params[:ticketForm] : {}
    Quote.new(
      event: @event,
      quantities: ticket_form[:quantities],
      prices: ticket_form[:prices],
      # Signed in, the form books as the account, so with its credit and any monthly donor's discount
      account: current_account,
      credit: true,
      # The code applied, rather than one typed into the box but not applied
      discount_code: ticket_form[:applied_discount_code],
      donation_amount: ticket_form[:donation_amount],
      secret_ticket_type_id: ticket_form[:ticket_type_id]
    ).validate!.to_json
  rescue OrderBuilder::Error => e
    halt e.status, { error: e.message }.to_json
  rescue Money::Currency::UnknownCurrency, Money::Bank::UnknownRate
    # An amount that can't be priced in the order's currency, which a booking would fail on too
    halt 400, { error: OrderBuilder::Error.new.message }.to_json
  end

  get '/e/:slug/orders/:order_id/payment_completed', provides: :json do
    @event = Event.find_by_slug_or_id(slug: params[:slug]) || not_found
    @order = @event.orders.find_by_id_or_token(params[:order_id]) || not_found
    @event.organisation.check_evm_account if @order.evm_secret && @event.organisation.evm_address
    @event.check_oc_event if @order.oc_secret && @event.oc_slug
    if @order.paypal_order_id && !@order.payment_completed?
      begin
        EventPaymentMethod::Paypal.complete_if_paid(@order)
        @order.reload
      rescue Paypal::RequestError => e
        ErrorReporting.capture_exception(e)
      end
    end
    { payment_completed: @order.payment_completed }.to_json
  end

  get '/e/:slug/orders/:order_id/ticketholders/:ticket_id/name' do
    @event = Event.find_by_slug_or_id(slug: params[:slug]) || not_found
    @order = @event.orders.complete.find_by_id_or_token(params[:order_id]) || not_found
    @ticket = @order.tickets.find_by_id_or_token(params[:ticket_id]) || not_found
    headers['Referrer-Policy'] = 'no-referrer'
    partial :'events/ticketholder_name', locals: { ticket: @ticket }
  end

  post '/e/:slug/orders/:order_id/ticketholders/:ticket_id/name' do
    @event = Event.find_by_slug_or_id(slug: params[:slug]) || not_found
    @order = @event.orders.complete.find_by_id_or_token(params[:order_id]) || not_found
    @ticket = @order.tickets.find_by_id_or_token(params[:ticket_id]) || not_found
    headers['Referrer-Policy'] = 'no-referrer'
    @ticket.set(name: params[:name])
    200
  end

  get '/e/:slug/orders/:order_id/ticketholders/:ticket_id/email' do
    @event = Event.find_by_slug_or_id(slug: params[:slug]) || not_found
    @order = @event.orders.complete.find_by_id_or_token(params[:order_id]) || not_found
    @ticket = @order.tickets.find_by_id_or_token(params[:ticket_id]) || not_found
    headers['Referrer-Policy'] = 'no-referrer'
    partial :'events/ticketholder_email', locals: { ticket: @ticket, success: params[:success] }
  end

  post '/e/:slug/orders/:order_id/ticketholders/:ticket_id/email' do
    @event = Event.find_by_slug_or_id(slug: params[:slug]) || not_found
    @order = @event.orders.complete.find_by_id_or_token(params[:order_id]) || not_found
    @ticket = @order.tickets.find_by_id_or_token(params[:ticket_id]) || not_found
    headers['Referrer-Policy'] = 'no-referrer'
    previous_email = @ticket.email
    @ticket.email = params[:email]
    @ticket.save
    @ticket.send_email_update_notification unless params[:success].to_i == 1
    @ticket.send_ticket if @event.send_ticketholder_confirmation && @ticket.errors.empty? && @ticket.email.present? && @ticket.email != previous_email && @ticket.email != @order.account&.email
    200
  end

  post '/tickets/:id/toggle_resale' do
    sign_in_required!
    @ticket = Ticket.find(params[:id]) || not_found
    halt 403 unless @ticket.account == current_account
    @event = @ticket.event
    # A ticket on resale leaves the event's ticket counts, freeing its place, and only events that allow resales refund and
    # remove it when the place sells (Ticket#payment_completed!): elsewhere the holder could free places, let them sell, and
    # take their tickets back off resale, overbooking the event
    halt 403 if !@ticket.made_available_at && !@event.enable_resales?
    if @ticket.made_available_at
      # Its place may already be held by a ticket that isn't paid for yet, which would replace it once paid for
      unless @ticket.fits_back_in_counts?
        flash[:error] = "Someone is buying this ticket's place, so it can't come off resale"
        redirect back
      end
      @ticket.made_available_at = nil
    else
      @ticket.made_available_at = Time.now
    end
    @ticket.save
    redirect back
  end

  # Old ticket emails and notifications link here; keep redirecting to confirm_cancel.
  get '/orders/:id/confirm_destroy' do
    qs = request.query_string
    redirect "/orders/#{params[:id]}/confirm_cancel#{"?#{qs}" if qs.present?}"
  end

  get '/orders/:id/confirm_cancel' do
    sign_in_required!
    @order = Order.find(params[:id]) || not_found
    @event = @order.event
    halt 403 unless @order.account == current_account
    halt 403 unless @order.value.nil? || @order.value.zero?
    @destroy_url = "/orders/#{@order.id}/destroy"
    erb :'orders/confirm_cancel'
  end

  post '/orders/:id/destroy' do
    sign_in_required!
    @order = Order.find(params[:id]) || not_found
    halt 403 unless @order.account == current_account
    halt 403 unless @order.value.nil? || @order.value.zero?
    @order.prevent_refund = true
    @order.destroy
    if params[:from_confirm]
      redirect "/e/#{@order.event.slug}"
    else
      redirect back
    end
  end

  get '/tickets/:id/confirm_cancel' do
    sign_in_required!
    @ticket = Ticket.find(params[:id]) || not_found
    @event = @ticket.event
    halt 403 unless @ticket.account == current_account
    halt 403 unless @ticket.cancellable?
    @destroy_url = "/tickets/#{@ticket.id}/destroy"
    erb :'orders/confirm_cancel'
  end

  post '/tickets/:id/destroy' do
    sign_in_required!
    @ticket = Ticket.find(params[:id]) || not_found
    @event = @ticket.event
    halt 403 unless @ticket.account == current_account
    halt 403 unless @ticket.cancellable?
    @ticket.destroy
    recipient = { 'email' => current_account.email, 'firstname' => current_account.firstname, 'token' => current_account.link_token_for_email, 'id' => current_account.id.to_s }
    Order.delay.send_rsvp_cancelled_email(@event.id.to_s, [recipient])
    if params[:from_confirm]
      redirect "/e/#{@event.slug}"
    else
      redirect back
    end
  end
end
