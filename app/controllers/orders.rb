Dandelion::App.controller do
  get '/o/:slug/orders', provides: %i[html csv] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @from = params[:from] ? parse_date(params[:from]) : nil
    @to = params[:to] ? parse_date(params[:to]) : nil
    @orders = @organisation.orders
    @orders = @orders.deleted if params[:deleted]
    @orders = @orders.and(:account_id.in => Account.search(params[:q]).pluck(:id)) if params[:q]
    @orders = @orders.and(:created_at.gte => @from) if @from
    @orders = @orders.and(:created_at.lt => @to + 1) if @to
    @orders = @orders.and(affiliate_type: 'Organisation', affiliate_id: params[:affiliate_id]) if params[:affiliate_id]
    case content_type
    when :html
      erb :'organisations/orders'
    when :csv
      CSV.generate do |csv|
        row = %w[name firstname lastname email value discounted_ticket_revenue donation_revenue currency opt_in_organisation opt_in_facilitator hear_about via created_at]
        csv << row
        @orders.each do |order|
          row = [
            order.account ? order.account.name : '',
            order.account ? order.account.firstname : '',
            order.account ? order.account.lastname : '',
            if order_email_viewer?(order)
              order.account ? order.account.email : ''
            else
              ''
            end,
            order.value,
            order.discounted_ticket_revenue,
            order.donation_revenue,
            order.currency,
            order.opt_in_organisation,
            order.opt_in_facilitator,
            order.hear_about,
            order.via,
            order.created_at.to_fs(:db_local)
          ]
          csv << row
        end
      end
    end
  end

  get '/events/:id/orders', provides: %i[html csv pdf] do
    @event = Event.unscoped.find(params[:id]) || not_found
    event_admins_only!
    @orders = @event.orders
    @orders =  @orders.discounted if params[:discounted]
    @orders =  @orders.deleted if params[:deleted]
    @orders =  @orders.complete if params[:complete]
    @orders =  @orders.incomplete if params[:incomplete]
    @orders = @orders.and(:account_id.in => Account.search(params[:q]).pluck(:id)) if params[:q]

    case content_type
    when :html
      if request.xhr?
        partial :'events/orders_table', locals: { orders: @orders, show_emails: event_email_viewer? }
      else
        erb :'events/orders'
      end
    when :csv
      CSV.generate do |csv|
        row = %w[name firstname lastname email value discounted_ticket_revenue donation_revenue currency opt_in_organisation opt_in_facilitator hear_about via created_at]
        @event.questions_a.each { |q| row << q }
        csv << row
        @orders.each do |order|
          row = [
            order.account ? order.account.name : '',
            order.account ? order.account.firstname : '',
            order.account ? order.account.lastname : '',
            if order_email_viewer?(order)
              order.account ? order.account.email : ''
            else
              ''
            end,
            order.value,
            order.discounted_ticket_revenue,
            order.donation_revenue,
            order.currency,
            order.opt_in_organisation,
            order.opt_in_facilitator,
            order.hear_about,
            order.via,
            order.created_at.to_fs(:db_local)
          ]
          @event.questions_a.each { |q| row << order.answers.to_h[q] } if order.answers
          csv << row
        end
      end
    when :pdf
      @orders = @orders.sort_by { |order| order.account.try(:name) || '' }
      Prawn::Document.new do |pdf|
        pdf.font "#{Padrino.root}/app/assets/fonts/PlusJakartaSans/ttf/PlusJakartaSans-Regular.ttf"
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
                 tt.tickets
               elsif params[:ticket_group_id]
                 tg = @event.ticket_groups.find(params[:ticket_group_id]) || not_found
                 tg.tickets
               else
                 @event.tickets
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
        @tickets.and(:account_id.in => Account.search(params[:q]).pluck(:id)).pluck(:id))
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

  get '/orders/:id', provides: %i[html pdf ics] do
    @order = Order.find(params[:id]) || not_found
    @event = @order.event
    event = @event
    order = @order
    account = @order.account || not_found
    pdf_link = true
    content = ERB.new(File.read(Padrino.root('app/views/emails/tickets.erb'))).result(binding)
                 .gsub('%recipient.token%', account.sign_in_token)

    header_image_url, from_email = order.sender_info

    case content_type
    when :html
      Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
    when :ics
      @event.ical(order: @order).to_ical
    when :pdf
      order.tickets_pdf.render
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
    @order.update_attribute(:transferred, true)
    @order.update_attribute(:event, new_event)
    @order.tickets.each do |ticket|
      ticket.update_attribute(:transferred, true)
      ticket.update_attribute(:event, new_event)
      ticket.update_attribute(:ticket_type, nil)
    end
    @order.donations.each do |donation|
      donation.update_attribute(:transferred, true)
      donation.update_attribute(:event, new_event)
    end
    @order.send_tickets
    @event.clear_cache
    flash[:notice] = 'The order was transferred.'
    redirect "/events/#{original_event_id}/orders"
  end

  get '/events/:id/orders/:order_id/payment_completed', provides: :json do
    @event = Event.find(params[:id]) || not_found
    @order = @event.orders.find(params[:order_id]) || not_found
    @event.organisation.check_evm_account if @order.evm_secret && @event.organisation.evm_address
    @event.check_oc_event if @order.oc_secret && @event.oc_slug
    { id: @order.id.to_s, payment_completed: @order.payment_completed }.to_json
  end

  get '/events/:id/orders/clear_answers' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.orders.unscoped.set(answers: nil)
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
    @ticket.update_attribute(:name, params[:name])
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

  get '/tickets/:id/toggle_resale' do
    @ticket = Ticket.find(params[:id]) || not_found
    halt 400 unless @ticket.account == current_account
    @event = @ticket.event
    @ticket.update_attribute(:made_available_at, @ticket.made_available_at ? nil : Time.now)
    redirect back
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
    @ticket.update_attribute(:discounted_price, params[:price])
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
    @ticket.update_attribute(:ticket_type_id, params[:ticket_type_id])
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
