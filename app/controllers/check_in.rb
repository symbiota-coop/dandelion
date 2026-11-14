Dandelion::App.controller do
  before do
    @event = event_from_params
    @check_in_secret = OpenSSL::HMAC.hexdigest('SHA256', ENV['CHECK_IN_SECRET'], "check_in:#{@event.id}")[0, 32]
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

  get '/e/:slug/check_in_toggle/:ticket_id' do
    # Gone once its order is cancelled or refunded, after the list showing it loaded
    ticket = @event.tickets.complete.find_by_id_or_token(params[:ticket_id]) || not_found
    partial :'events/check_in_toggle', locals: { ticket: ticket }
  end

  post '/e/:slug/check_in/:ticket_id' do
    ticket = @event.tickets.complete.find_by_id_or_token(params[:ticket_id])
    if !ticket
      403
    elsif !ticket.checked_in == params[:checked_in].nil? # already checked in, or already not
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
    @tickets = event_tickets_from_params(:account, :ticket_type)

    if request.xhr?
      partial :'events/check_in_list_table', locals: { tickets: @tickets }
    else
      erb :'events/check_in_list'
    end
  end
end
