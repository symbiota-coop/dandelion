Dandelion::App.controller do
  get '/orders/:id', provides: %i[html pdf ics] do
    @order = Order.find(params[:id]) || not_found
    @event = @order.event
    event = @event
    order = @order
    account = @order.account || not_found
    pdf_link = true

    tickets_table = ERB.new(File.read(Padrino.root('app/views/emails/_tickets_table.erb'))).result(binding)
    content = ERB.new(File.read(Padrino.root('app/views/emails/tickets.erb'))).result(binding)
                 .gsub('%recipient.token%', account.sign_in_token)

    header_image_url, from_email = order.sender_info

    case content_type
    when :html
      @title = "Order confirmation for #{@event.name}"
      Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
    when :ics
      @event.ical(order: @order).to_ical
    when :pdf
      order.tickets_pdf.render
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
    halt 400 unless @ticket.account == current_account
    @event = @ticket.event
    @ticket.set(made_available_at: @ticket.made_available_at ? nil : Time.now)
    redirect back
  end
end
