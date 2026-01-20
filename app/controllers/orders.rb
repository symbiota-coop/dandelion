Dandelion::App.controller do
  get '/orders/:id', provides: %i[html pdf ics] do
    @order = Order.find(params[:id]) || not_found
    @event = @order.event
    account = @order.account || not_found

    case content_type
    when :html
      @title = "Order confirmation for #{@event.name}"
      header_image_url, = @order.sender_info

      tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: account)
      EmailHelper.html(:tickets, event: @event, order: @order, account: account, tickets_table: tickets_table, header_image_url: header_image_url, pdf_link: true) do |content|
        content.gsub('%recipient.token%', account.sign_in_token)
      end

    when :ics
      @event.ical(order: @order).to_ical
    when :pdf
      @order.tickets_pdf.render
    end
  end

  get '/events/:id/orders/:order_id/payment_completed', provides: :json do
    @event = Event.find(params[:id]) || not_found
    @order = @event.orders.find(params[:order_id]) || not_found
    @event.organisation.check_evm_account if @order.evm_secret && @event.organisation.evm_address
    @event.check_oc_event if @order.oc_secret && @event.oc_slug
    { id: @order.id.to_s, payment_completed: @order.payment_completed }.to_json
  end

  get '/events/:id/orders/:order_id/ticketholders/:ticket_id/name' do
    @event = Event.find(params[:id]) || not_found
    @order = @event.orders.complete.find(params[:order_id]) || not_found
    @ticket = @order.tickets.find(params[:ticket_id])
    partial :'events/ticketholder_name', locals: { ticket: @ticket }
  end

  post '/events/:id/orders/:order_id/ticketholders/:ticket_id/name' do
    @event = Event.find(params[:id]) || not_found
    @order = @event.orders.complete.find(params[:order_id]) || not_found
    @ticket = @order.tickets.find(params[:ticket_id]) || not_found
    @ticket.set(name: params[:name])
    200
  end

  get '/events/:id/orders/:order_id/ticketholders/:ticket_id/email' do
    @event = Event.find(params[:id]) || not_found
    @order = @event.orders.complete.find(params[:order_id]) || not_found
    @ticket = @order.tickets.find(params[:ticket_id])
    partial :'events/ticketholder_email', locals: { ticket: @ticket, success: params[:success] }
  end

  post '/events/:id/orders/:order_id/ticketholders/:ticket_id/email' do
    @event = Event.find(params[:id]) || not_found
    @order = @event.orders.complete.find(params[:order_id]) || not_found
    @ticket = @order.tickets.find(params[:ticket_id]) || not_found
    @ticket.email = params[:email]
    @ticket.save
    @ticket.send_email_update_notification unless params[:success].to_i == 1
    200
  end

  get '/tickets/:id/toggle_resale' do
    @ticket = Ticket.find(params[:id]) || not_found
    halt 403 unless @ticket.account == current_account
    @event = @ticket.event
    @ticket.set(made_available_at: @ticket.made_available_at ? nil : Time.now)
    redirect back
  end

  get '/orders/:id/destroy' do
    @order = Order.find(params[:id]) || not_found
    halt 403 unless @order.account == current_account
    halt 403 unless @order.value.nil? || @order.value.zero?
    @order.prevent_refund = true
    @order.destroy
    redirect back
  end
end
