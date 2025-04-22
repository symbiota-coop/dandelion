Dandelion::App.controller do
  before do
    @event = params[:slug] ? Event.find_by(slug: params[:slug]) : Event.find(params[:id]) || not_found
    @check_in_secret = Digest::SHA256.hexdigest("#{@event.id}#{ENV['SESSION_SECRET']}")[0..7]
    @check_in_url = "#{ENV['BASE_URI']}/e/#{@event.slug}/check_in?p=#{@check_in_secret}"
    if params[:p] || session[:check_in_secret]
      halt 403 unless (params[:p] && params[:p] == @check_in_secret) || (session[:check_in_secret] && session[:check_in_secret] == @check_in_secret)
      session[:check_in_secret] = @check_in_secret
    else
      event_admins_only!
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
        ticket.update_attribute(:checked_in, true)
        ticket.update_attribute(:checked_in_at, Time.now)
      else
        ticket.update_attribute(:checked_in, nil)
      end
      ticket.account ? ticket.account.name : ''
    end
  end

  get '/e/:slug/check_in_list' do
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
        Ticket.collection.aggregate([
                                      { '$addFields' => { 'id' => { '$toString' => '$_id' } } },
                                      { '$match' => { 'id' => { '$regex' => /#{Regexp.escape(params[:q])}/i } } }
                                    ]).pluck(:id) +
        Ticket.unscoped.and(
          :account_id.in => search_accounts(params[:q]).pluck(:id)
        ).pluck(:id))
    end

    if request.xhr?
      partial :'events/check_in_list_table', locals: { tickets: @tickets }
    else
      erb :'events/check_in_list'
    end
  end
end
