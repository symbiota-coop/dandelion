Dandelion::App.controller do
  get '/o/:slug/orders', provides: %i[html csv] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @from = params[:from] ? parse_date(params[:from]) : nil
    @to = params[:to] ? parse_date(params[:to]) : nil
    @orders = @organisation.orders.includes(:account, :event, :revenue_sharer, :discount_code)
    @orders = @orders.deleted if params[:deleted]
    @orders = @orders.and(:account_id.in => Account.search(params[:q], child_scope: @orders, regex_search: true).pluck(:id)) if params[:q]
    @orders = @orders.and(:created_at.gte => @from) if @from
    @orders = @orders.and(:created_at.lt => @to + 1) if @to
    @orders = @orders.and(affiliate_type: 'Organisation', affiliate_id: params[:affiliate_id]) if params[:affiliate_id]
    case content_type
    when :html
      erb :'organisations/orders'
    when :csv
      @orders.generate_csv(account: current_account)
    end
  end

  get '/events/:id/orders', provides: %i[html csv pdf] do
    @event = Event.unscoped.find(params[:id]) || not_found
    event_admins_only!
    @orders = @event.orders.includes(:account, :revenue_sharer, :discount_code)
    @orders =  @orders.discounted if params[:discounted]
    @orders =  @orders.deleted if params[:deleted]
    @orders =  @orders.complete if params[:complete]
    @orders =  @orders.incomplete if params[:incomplete]
    @orders = @orders.and(:account_id.in => Account.search(params[:q], child_scope: @orders, regex_search: true).pluck(:id)) if params[:q]

    case content_type
    when :html
      if request.xhr?
        partial :'events/orders_table', locals: { orders: @orders, show_emails: event_email_viewer? }
      else
        erb :'events/orders'
      end
    when :csv
      @orders.generate_csv(account: current_account, event: @event)
    when :pdf
      @orders = @orders.sort_by { |order| order.account.try(:name) || '' }
      Prawn::Document.new do |pdf|
        pdf.font "#{Padrino.root}/app/assets/fonts/PlusJakartaSans/ttf/PlusJakartaSans-Regular.ttf"
        pdf.font_size 10
        pdf.table([%w[name email value currency created_at]] +
            @orders.map do |order|
              [
                order.account ? order.account.name_transliterated : '',
                if order_email_viewer?(order)
                  order.account ? order.account.email : ''
                else
                  ''
                end,
                order.value,
                order.currency,
                order.created_at.to_fs(:db_local)
              ]
            end)
      end.render
    end
  end

  get '/events/:id/tickets', provides: %i[html csv pdf] do
    @event = Event.unscoped.find(params[:id]) || not_found
    event_admins_only!
    @tickets = if params[:ticket_type_id]
                 tt = @event.ticket_types.find(params[:ticket_type_id]) || not_found
                 tt.tickets.includes(:account, :ticket_type, :order)
               elsif params[:ticket_group_id]
                 tg = @event.ticket_groups.find(params[:ticket_group_id]) || not_found
                 tg.tickets.includes(:account, :ticket_type, :order)
               else
                 @event.tickets.includes(:account, :ticket_type, :order)
               end
    @tickets =  @tickets.discounted if params[:discounted]
    @tickets =  @tickets.deleted if params[:deleted]
    @tickets =  @tickets.complete if params[:complete]
    @tickets =  @tickets.incomplete if params[:incomplete]
    if params[:q]
      @tickets = @tickets.and(:id.in =>
        @tickets.and(id_string: /#{Regexp.escape(params[:q])}/i).pluck(:id) +
        @tickets.and(name: /#{Regexp.escape(params[:q])}/i).pluck(:id) +
        @tickets.and(email: /#{Regexp.escape(params[:q])}/i).pluck(:id) +
        @tickets.and(:account_id.in => Account.search(params[:q], child_scope: @tickets, regex_search: true).pluck(:id)).pluck(:id))
    end
    case content_type
    when :html
      if request.xhr?
        partial :'events/tickets_table', locals: { tickets: @tickets }
      else
        erb :'events/tickets'
      end
    when :csv
      CSV.generate do |csv|
        csv << %w[name firstname lastname email ordered_for_name ordered_for_email ticket_type price currency created_at checked_in_at]
        @tickets.each do |ticket|
          csv << [
            ticket.account ? ticket.account.name : '',
            ticket.account ? ticket.account.firstname : '',
            ticket.account ? ticket.account.lastname : '',
            ticket.account && ticket_email_viewer?(ticket) ? ticket.account.email : '',
            ticket.name,
            ticket_email_viewer?(ticket) ? ticket.email : '',
            ticket.ticket_type.try(:name),
            ticket.discounted_price,
            ticket.currency,
            ticket.created_at.to_fs(:db_local),
            ticket.checked_in_at ? ticket.checked_in_at.to_fs(:db_local) : ''
          ]
        end
      end
    when :pdf
      @tickets = @tickets.sort_by { |ticket| ticket.account ? ticket.account.name : '' }
      Prawn::Document.new(page_layout: :landscape) do |pdf|
        pdf.font "#{Padrino.root}/app/assets/fonts/PlusJakartaSans/ttf/PlusJakartaSans-Regular.ttf"
        pdf.font_size 8
        pdf.table([%w[name email ordered_for_name ordered_for_email ticket_type price currency created_at checked_in_at]] +
            @tickets.map do |ticket|
              [
                ticket.account ? ticket.account.name_transliterated : '',
                ticket.account && ticket_email_viewer?(ticket) ? ticket.account.email : '',
                (I18n.transliterate(ticket.name) if ticket.name),
                ticket_email_viewer?(ticket) ? ticket.email : '',
                ticket.ticket_type.try(:name),
                ticket.discounted_price,
                ticket.currency,
                ticket.created_at.to_fs(:db_local),
                ticket.checked_in_at ? ticket.checked_in_at.to_fs(:db_local) : ''
              ]
            end)
      end.render
    end
  end

  get '/orders/:id/send_tickets' do
    @order = Order.find(params[:id]) || not_found
    @event = @order.event
    event_admins_only!
    @order.send_tickets
    flash[:notice] = 'The tickets for the order were resent.'
    redirect back
  end

  get '/orders/:id/transfer' do
    @order = Order.find(params[:id]) || not_found
    @event = @order.event
    event_admins_only!
    erb :'events/transfer_order'
  end

  post '/orders/:id/transfer' do
    @order = Order.find(params[:id]) || not_found
    @event = @order.event
    @organisation = @event.organisation
    original_event_id = @order.event_id
    event_admins_only!
    new_event = @event.organisation.events.find(params[:order][:event_id]) || not_found
    halt 400 unless event_admin?(new_event)
    @order.set(transferred: true)
    @order.set(event_id: new_event.id)
    @order.tickets.each do |ticket|
      ticket.set(transferred: true)
      ticket.set(event_id: new_event.id)
      ticket.set(ticket_type: nil)
    end
    @order.donations.each do |donation|
      donation.set(transferred: true)
      donation.set(event_id: new_event.id)
    end
    @order.send_tickets
    @event.clear_cache
    flash[:notice] = 'The order was transferred.'
    redirect "/events/#{original_event_id}/orders"
  end

  get '/events/:id/orders/clear_answers' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.orders.unscoped.update_all(answers: nil)
    redirect back
  end

  get '/events/:id/orders/:order_id/refund_and_destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    order = @event.orders.find(params[:order_id]) || not_found
    order.destroy # calls order.refund
    redirect back
  end

  get '/events/:id/orders/:order_id/destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    order = @event.orders.find(params[:order_id]) || not_found
    order.prevent_refund = true
    order.destroy
    redirect back
  end

  get '/events/:id/orders/:order_id/restore_and_complete' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.orders.deleted.find(params[:order_id]).restore_and_complete
    redirect back
  end

  get '/events/:id/tickets/:ticket_id/restore' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.tickets.deleted.find(params[:ticket_id]).restore
    redirect back
  end

  get '/tickets/:id/send_ticket' do
    @ticket = Ticket.find(params[:id]) || not_found
    @event = @ticket.event
    event_admins_only!
    @ticket.send_ticket
    flash[:notice] = 'The ticket was resent.'
    redirect back
  end

  get '/tickets/:id/edit' do
    @ticket = Ticket.find(params[:id]) || not_found
    @event = @ticket.event
    event_admins_only!
    erb :'events/ticket'
  end

  post '/tickets/:id/edit' do
    @ticket = Ticket.find(params[:id]) || not_found
    @event = @ticket.event
    event_admins_only!
    if @ticket.update_attributes(name: params[:ticket][:name], email: params[:ticket][:email])
      flash[:notice] = 'The ticket was updated.'
      redirect "/events/#{@event.id}/tickets"
    else
      flash.now[:error] = 'There was an error updating the ticket.'
      erb :'events/ticket'
    end
  end

  get '/tickets/:id/price' do
    @ticket = Ticket.find(params[:id]) || not_found
    @event = @ticket.event
    event_admins_only!
    partial :'events/ticket_price', locals: { ticket: @ticket }
  end

  post '/tickets/:id/price' do
    @ticket = Ticket.find(params[:id]) || not_found
    @event = @ticket.event
    event_admins_only!
    @ticket.set(discounted_price: params[:price])
    200
  end

  get '/tickets/:id/ticket_type' do
    @ticket = Ticket.find(params[:id]) || not_found
    @event = @ticket.event
    event_admins_only!
    partial :'events/ticket_type', locals: { ticket: @ticket }
  end

  post '/tickets/:id/ticket_type' do
    @ticket = Ticket.find(params[:id]) || not_found
    @event = @ticket.event
    event_admins_only!
    @ticket.set(ticket_type_id: params[:ticket_type_id])
    200
  end

  get '/events/:id/tickets/:ticket_id/refund_and_destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    ticket = @event.tickets.find(params[:ticket_id]) || not_found
    ticket.refund
    ticket.destroy
    redirect back
  end

  get '/events/:id/tickets/:ticket_id/destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    ticket = @event.tickets.find(params[:ticket_id]) || not_found
    ticket.destroy
    redirect back
  end
end
