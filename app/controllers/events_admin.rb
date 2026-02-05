Dandelion::App.controller do
  get '/e/:slug/edit' do
    @event = Event.unscoped.find_by(slug: params[:slug]) || not_found
    kick! unless @event.organisation
    event_admins_only!
    erb :'events_build/build'
  end

  post '/e/:slug/edit' do
    @event = Event.find_by(slug: params[:slug]) || not_found
    kick! unless @event.organisation
    event_admins_only!
    @event.last_saved_by = current_account
    if @event.update_attributes(mass_assigning(params[:event], Event))
      @event.lock! if !@event.organisation.payment_method? && @event.paid_tickets?
      flash[:notice] = 'The event was saved.'
      redirect "/e/#{@event.slug}/edit"
    else
      @edit_slug = params[:slug] # Use original slug for form action, not the (possibly invalid) in-memory value
      flash.now[:error] = 'There was an error saving the event.'
      erb :'events_build/build'
    end
  end

  get '/events/:id/delete' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/delete'
  end

  get '/events/:id/destroy' do
    @event = Event.find(params[:id]) || not_found
    @organisation = @event.organisation
    organisation_admins_only!
    @event.set(refund_deleted_orders: false) if params[:no_refunds]
    @event.send_destroy_notification(current_account)
    @event.destroy
    flash[:notice] = 'The event was deleted.'
    redirect "/o/#{@event.organisation.slug}/events"
  end

  get '/events/:id/progress' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    partial :'events/progress', locals: { event: @event, full_width: params[:full_width] }
  end

  get '/events/:id/stats_row' do
    @event = Event.unscoped.find(params[:id]) || not_found
    @organisation = Organisation.find(params[:organisation_id]) || not_found
    event_admins_only!
    cp(:'events/event_stats_row', locals: { event: @event, organisation: @organisation, event_revenue_admin: event_revenue_admin? }, event: @event, key: "/events/#{@event.id}/stats_row?timezone=#{@event.start_time&.strftime('%Z')}&organisation_id=#{@organisation.id}&event_revenue_admin=#{event_revenue_admin? ? 1 : 0}")
  end

  get '/events/:id/duplicate' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    if Padrino.env == :production && !@event.organisation.stripe_client_id && @event.organisation.stripe_sk && !@event.organisation.stripe_connect_json
      @organisation = @event.organisation
      erb :'events/stripe_connect'
    elsif @event.organisation.contribution_required
      redirect "/o/#{@event.organisation.slug}/contribute"
    else
      duplicated_event = @event.duplicate!(current_account)
      redirect "/e/#{duplicated_event.slug}/edit?duplicated=1"
    end
  end

  get '/events/:id/ticket_email' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/ticket_email'
  end

  get '/events/:id/ticket_email_preview' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    order = @event.orders.new
    order.tickets.new(ticket_type: @event.ticket_types.first)
    order.tickets.new(ticket_type: @event.ticket_types.first)
    order.account = current_account
    header_image_url, = order.sender_info

    tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: current_account)
    EmailHelper.html(:tickets, event: @event, order: order, account: current_account, tickets_table: tickets_table, header_image_url: header_image_url) do |content|
      content.gsub('%recipient.token%', current_account.sign_in_token)
    end
  end

  get '/events/:id/reminder_email' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/reminder_email'
  end

  get '/events/:id/reminder_email_preview' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!

    tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: current_account)
    EmailHelper.html(:reminder, event: @event, tickets_table: tickets_table) do |content|
      content.gsub('%recipient.firstname%', current_account.firstname)
             .gsub('%recipient.token%', current_account.sign_in_token)
    end
  end

  get '/events/:id/feedback_request_email' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/feedback_request_email'
  end

  get '/events/:id/feedback_request_email_preview' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    EmailHelper.html(:feedback, event: @event) do |content|
      content.gsub('%recipient.firstname%', current_account.firstname)
             .gsub('%recipient.token%', current_account.sign_in_token)
             .gsub('%recipient.id%', current_account.id)
    end
  end

  post '/events/:id/create_ticket' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!

    account_hash = { name: params[:ticket][:name], email: params[:ticket][:email] }
    @account = if account_hash[:email] && (account = Account.find_by(email: account_hash[:email].downcase))
                 account
               else
                 Account.new(mass_assigning(account_hash, Account))
               end

    successful_update_or_save = if @account.persisted?
                                  @account.update_attributes(mass_assigning(account_hash.map { |k, v| [k, v] if v }.compact.to_h, Account))
                                else
                                  @account.save
                                end
    if successful_update_or_save
      ticket = @account.tickets.create(event: @event, ticket_type: params[:ticket][:ticket_type_id], price: params[:ticket][:price], complimentary: true)
      if ticket.persisted?
        ticket.send_ticket
      else
        flash[:error] = ticket.errors.full_messages.join('; ')
      end
    else
      flash[:error] = @account.errors.full_messages.join('; ')
    end
    redirect "/events/#{@event.id}/tickets"
  end

  get '/events/:id/stripe_charges' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @stripe_charges = @event.stripe_charges.includes(:account, order: :account).and(:balance_transaction.ne => nil)
    @stripe_charges = @stripe_charges.and(:account_id.in => Account.search(params[:q], child_scope: @stripe_charges).pluck(:id)) if params[:q]

    if request.xhr?
      partial :'events/stripe_charges_table', locals: { stripe_charges: @stripe_charges, show_emails: event_email_viewer? }
    else
      erb :'events/stripe_charges'
    end
  end

  get '/events/:id/donations' do
    @event = Event.unscoped.find(params[:id]) || not_found
    event_admins_only!
    @donations = @event.donations.includes(:account, :order)
    @donations = @donations.and(:account_id.in => Account.search(params[:q], child_scope: @donations).pluck(:id)) if params[:q]
    erb :'events/donations'
  end

  get '/events/:id/stats' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/stats'
  end

  get '/events/:id/waitlist' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @waitships = @event.waitships.includes(:account)
    @waitships = @waitships.and(:account_id.in => Account.search(params[:q], child_scope: @waitships).pluck(:id)) if params[:q]
    erb :'events/waitlist'
  end

  post '/events/:id/event_facilitations/new' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.event_facilitations.create(account_id: params[:event_facilitation][:account_id])
    redirect back
  end

  post '/events/:id/event_facilitations/destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.event_facilitations.find_by(account_id: params[:account_id]).try(:destroy)
    redirect back
  end

  get '/events/:id/pmails' do
    @event = Event.find(params[:id]) || not_found
    @_organisation = @event.organisation
    event_admins_only!
    @pmails = @event.pmails_as_mailable.includes(:account).order('created_at desc').paginate(page: params[:page])
    @scope = "event_id=#{@event.id}"
    erb :'pmails/pmails'
  end

  post '/events/:id/cohostships/new' do
    @event = Event.find(params[:id]) || not_found
    if params[:cohostship] && params[:cohostship][:organisation_id]
      @organisation = Organisation.find(params[:cohostship][:organisation_id]) || not_found
      @organisation.restrict_cohosting? ? organisation_admins_only! : event_admins_only!
      @event.cohostships.create(organisation: @organisation)
    end
    redirect back
  end

  post '/events/:id/cohostships/destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.cohostships.find_by(organisation_id: params[:organisation_id]).try(:destroy)
    redirect back
  end

  get '/events/:id/cohosts' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/cohosts'
  end

  post '/events/:id/cohostships/:cohostship_id' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @cohostship = @event.cohostships.find(params[:cohostship_id])
    if @cohostship.update_attributes(mass_assigning(params[:cohostship], Cohostship))
      redirect "/events/#{@event.id}/cohosts"
    else
      flash.now[:error] = 'There was an error saving the cohost.'
      erb :'events/cohosts'
    end
  end

  get '/events/:id/ticket_types' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/ticket_types'
  end

  get '/events/:id/notes' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    partial :'events/notes'
  end

  post '/events/:id/notes' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.set(notes: params[:notes])
    200
  end

  get '/events/:id/resend_feedback_email/:account_id' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.send_feedback_requests(params[:account_id])
    flash[:notice] = 'The feedback email was resent.'
    redirect back
  end

  get '/events/:id/discount_codes' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @discount_codes = @event.discount_codes
    @scope = "event_id=#{@event.id}"
    erb :'discount_codes/discount_codes'
  end

  post '/events/:id/event_sessions/new' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.event_sessions.create(mass_assigning(params[:event_session], EventSession))
    redirect back
  end

  post '/events/:id/event_sessions/destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.event_sessions.find(params[:event_session_id]).try(:destroy)
    redirect back
  end

  get '/events/:id/hide_from_homepage' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    partial :'events/hide_from_homepage', locals: { event: @event, block_edit: params[:block_edit] }
  end

  get '/events/:id/do_hide_from_homepage' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.set(hidden_from_homepage: true)
    200
  end

  get '/events/:id/unhide_from_homepage' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.set(hidden_from_homepage: false)
    200
  end

  get '/events/:id/checked_in' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    partial :'events/checked_in', locals: { event: @event }
  end
end
