Dandelion::App.controller do
  before do
    @event = (params[:slug] ? Event.find_by(slug: params[:slug]) : Event.find(params[:id])) || not_found
    @check_in_secret = OpenSSL::HMAC.hexdigest('SHA256', ENV['SESSION_SECRET'], "check_in:#{@event.id}")[0, 32]
    @check_in_url = "#{ENV['BASE_URI']}/e/#{@event.slug}/check_in?secret=#{@check_in_secret}"
    unless event_admin?
      provided = params[:secret] || session[:"check_in_secret_#{@event.id}"]
      if provided
        if ActiveSupport::SecurityUtils.secure_compare(provided.to_s, @check_in_secret)
          session[:"check_in_secret_#{@event.id}"] = provided
        else
          halt 403, erb(:'events/check_in_secret_error')
        end
      else
        event_admins_only!
      end
    end
  end

  get '/e/:slug/check_in' do
    erb :'events/check_in'
  end

  get '/events/:id/check_in_toggle/:ticket_id' do
    ticket = @event.tickets.complete.find(params[:ticket_id])
    partial :'events/check_in_toggle', locals: { ticket: ticket }
  end

  post '/events/:id/check_in/:ticket_id' do
    ticket = @event.tickets.complete.find(params[:ticket_id])
    if !ticket
      403
    elsif params[:checked_in] && ticket.checked_in
      409
    elsif !params[:checked_in] && !ticket.checked_in
      409
    else
      if params[:checked_in]
        ticket.set(checked_in: true)
        ticket.set(checked_in_at: Time.now)
      else
        ticket.set(checked_in: false)
      end
      ticket.account ? ticket.account.name : ''
    end
  end

  get '/e/:slug/check_in_list' do
    @tickets = if params[:ticket_type_id]
                 tt = @event.ticket_types.find(params[:ticket_type_id]) || not_found
                 tt.tickets.includes(:account, :ticket_type)
               elsif params[:ticket_group_id]
                 tg = @event.ticket_groups.find(params[:ticket_group_id]) || not_found
                 tg.tickets.includes(:account, :ticket_type)
               else
                 @event.tickets.includes(:account, :ticket_type)
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

    if request.xhr?
      partial :'events/check_in_list_table', locals: { tickets: @tickets }
    else
      erb :'events/check_in_list'
    end
  end
end
