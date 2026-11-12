Dandelion::App.controller do
  get '/e/:slug/edit' do
    @event = event_from_params(Event.unscoped.without(:voyage_embedding))
    kick! unless @event.organisation
    event_admins_only!
    erb :'events_build/build'
  end

  post '/e/:slug/edit' do
    @event = event_from_params
    kick! unless @event.organisation
    event_admins_only!
    @event.last_saved_by = current_account
    params[:event].delete('locked') if @event.locked? && !event_lock_admin?
    if !@event.organisation.payment_method? && @event.paid_tickets?
      params[:event].delete('locked')
      @event.locked = true
    end
    if @event.update_attributes(mass_assigning(params[:event], Event))
      @event.delete_atproto if @event.locked
      flash[:notice] = 'The event was saved.'
      redirect "/e/#{@event.slug}/edit"
    else
      @edit_slug = params[:slug] # Use original slug for form action, not the (possibly invalid) in-memory value
      flash.now[:error] = 'There was an error saving the event.'
      erb :'events_build/build'
    end
  end

  get '/e/:slug/delete' do
    @event = event_from_params
    event_admins_only!
    erb :'events/delete'
  end

  post '/e/:slug/destroy' do
    @event = event_from_params
    can_delete_event_only!
    @event.prevent_order_refunds = true if params[:no_refunds]
    @event.send_destroy_notification(current_account)
    @event.destroy
    flash[:notice] = 'The event was deleted.'
    redirect "/o/#{@event.organisation.slug}/events"
  end

  get '/e/:slug/progress' do
    @event = event_from_params
    event_admins_only!
    partial :'events/progress', locals: { event: @event, full_width: params[:full_width] }
  end

  get '/e/:slug/linked_image' do
    @event = event_from_params(Event.unscoped)
    @organisation = Organisation.find(params[:organisation_id]) || not_found
    event_admins_or_revenue_admins_only!
    image_source = @event.image_source(@organisation) || not_found
    partial :'event_stats_row/linked_image', locals: { event: @event, image_source: image_source }
  end

  get '/e/:slug/duplicate' do
    @event = event_from_params
    event_admins_only!
    duplicate_event_prerequisites!
    erb :'events/duplicate'
  end

  post '/e/:slug/duplicate' do
    @event = event_from_params
    event_admins_only!
    duplicate_event_prerequisites!
    duplicated_event = @event.duplicate!(current_account)
    redirect "/e/#{duplicated_event.slug}/edit"
  end

  get '/e/:slug/ticket_email' do
    @event = event_from_params
    event_admins_only!
    erb :'events/ticket_email'
  end

  get '/e/:slug/ticket_email_preview' do
    @event = event_from_params
    event_admins_only!
    email_html_csp!
    order = @event.orders.new
    order.tickets.new(ticket_type: @event.ticket_types.first)
    order.tickets.new(ticket_type: @event.ticket_types.first)
    order.account = current_account
    header_image_url, = order.sender_info

    tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: current_account)
    EmailHelper.html(:tickets, event: @event, order: order, account: current_account, tickets_table: tickets_table, header_image_url: header_image_url) do |content|
      content.gsub('%recipient.token%', '') # a preview isn't sent, so it must not show a working link token
    end
  end

  get '/e/:slug/reminder_email' do
    @event = event_from_params
    event_admins_only!
    erb :'events/reminder_email'
  end

  get '/e/:slug/reminder_email_preview' do
    @event = event_from_params
    event_admins_only!
    email_html_csp!

    tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: current_account)
    EmailHelper.html(:reminder, event: @event, tickets_table: tickets_table) do |content|
      EmailFields.replace_recipient_variables(
        content,
        EmailFields.recipient_variables(
          event: @event,
          account: current_account,
          token: false
        )
      )
    end
  end

  get '/e/:slug/feedback_request_email' do
    @event = event_from_params
    event_admins_only!
    erb :'events/feedback_request_email'
  end

  get '/e/:slug/feedback_request_email_preview' do
    @event = event_from_params
    event_admins_only!
    email_html_csp!
    EmailHelper.html(:feedback, event: @event) do |content|
      EmailFields.replace_recipient_variables(
        content,
        EmailFields.recipient_variables(
          event: @event,
          account: current_account,
          token: false
        ).merge('feedback_token' => @event.feedback_preview_token)
      )
    end
  end

  post '/e/:slug/create_ticket' do
    @event = event_from_params
    event_admins_only!

    account_hash = { name: params[:ticket][:name], email: params[:ticket][:email] }
    @account = if account_hash[:email] && (account = Account.find_by(email: account_hash[:email].downcase.strip))
                 account
               else
                 Account.new(mass_assigning(account_hash, Account))
               end

    successful_update_or_save = save_or_update_account_from_email_form(@account, account_hash)
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
    redirect "/e/#{@event.slug}/tickets"
  end

  get '/e/:slug/stripe_charges' do
    @event = event_from_params
    event_admins_only!
    @stripe_charges = @event.stripe_charges.includes(:account, order: %i[account event]).and(:balance_transaction.ne => nil)
    @stripe_charges = @stripe_charges.and(:account_id.in => Account.search(params[:q], child_scope: @stripe_charges, regex_search: true).pluck(:id)) if params[:q]

    if request.xhr?
      partial :'events/stripe_charges_table', locals: { stripe_charges: @stripe_charges, show_emails: event_email_viewer? }
    else
      erb :'events/stripe_charges'
    end
  end

  get '/e/:slug/donations' do
    @event = event_from_params(Event.unscoped)
    event_admins_only!
    @donations = @event.donations.includes(:account, :order)
    @donations = @donations.and(:account_id.in => Account.search(params[:q], child_scope: @donations, regex_search: true).pluck(:id)) if params[:q]
    erb :'events/donations'
  end

  get '/e/:slug/stats' do
    @event = event_from_params
    event_admins_only!
    erb :'events/stats'
  end

  get '/e/:slug/stripe_report' do
    @event = event_from_params(Event.unscoped)
    event_revenue_admins_only!
    not_found if @event.organisation.stripe_client_id || !@event.organisation.stripe_connect_json
    begin
      @stripe_report = @event.stripe_report
      @orders = Order.unscoped.and(:id.in => @stripe_report[:charges].map { |charge| charge[:order_id] }.compact).index_by { |order| order.id.to_s }
    rescue Stripe::StripeError => e
      @stripe_error = e.message
    end
    erb :'events/stripe_report'
  end

  get '/e/:slug/waitlist' do
    @event = event_from_params
    event_admins_only!
    @waitships = @event.waitships.includes(:account)
    @waitships = @waitships.and(:account_id.in => Account.search(params[:q], child_scope: @waitships, regex_search: true).pluck(:id)) if params[:q]
    erb :'events/waitlist'
  end

  get '/e/:slug/ticket_type_waitlists' do
    @event = event_from_params
    event_admins_only!
    @ticket_type_waitships = TicketTypeWaitship.and(:ticket_type_id.in => @event.ticket_type_ids).includes(:account, :ticket_type)
    @ticket_type_waitships = @ticket_type_waitships.and(ticket_type_id: params[:ticket_type_id]) if params[:ticket_type_id]
    @ticket_type_waitships = @ticket_type_waitships.and(:account_id.in => Account.search(params[:q], child_scope: @ticket_type_waitships, regex_search: true).pluck(:id)) if params[:q]
    erb :'events/ticket_type_waitlists'
  end

  # The add/remove boxes on an event's page are pagelets, which reload from these after each add or remove
  get '/e/:slug/event_facilitations' do
    @event = event_from_params
    event_admins_only!
    partial :'events/facilitators_box'
  end

  get '/e/:slug/cohostships' do
    @event = event_from_params
    event_admins_only!
    partial :'events/cohosts_box'
  end

  get '/e/:slug/event_sessions' do
    @event = event_from_params
    event_admins_only!
    partial :'events/sessions_box'
  end

  post '/e/:slug/event_facilitations/new' do
    @event = event_from_params
    event_admins_only!
    @event.event_facilitations.create(account_id: params[:event_facilitation][:account_id])
    redirect back
  end

  post '/e/:slug/event_facilitations/destroy' do
    @event = event_from_params
    event_admins_only!
    @event.event_facilitations.find_by(account_id: params[:account_id]).try(:destroy)
    redirect back
  end

  get '/e/:slug/pmails' do
    @event = event_from_params
    @_organisation = @event.organisation
    event_admins_only!
    @pmails = @event.pmails_as_mailable.includes(:account).order('created_at desc').paginate(page: params[:page])
    @scope = "event_id=#{@event.id}"
    erb :'pmails/pmails'
  end

  post '/e/:slug/cohostships/new' do
    @event = event_from_params
    event_admins_only!
    kick!(redirect_url: "/e/#{@event.slug}") unless event_cohost_adder?
    if params[:cohostship] && params[:cohostship][:organisation_id]
      @organisation = Organisation.find(params[:cohostship][:organisation_id]) || not_found
      organisation_admins_or_event_managers_only! if @organisation.restrict_cohosting?
      @event.cohostships.create(organisation: @organisation)
    end
    redirect back
  end

  post '/e/:slug/cohostships/destroy' do
    @event = event_from_params
    event_admins_only!
    kick!(redirect_url: "/e/#{@event.slug}") unless event_cohost_remover?
    @event.cohostships.find_by(organisation_id: params[:organisation_id]).try(:destroy)
    redirect back
  end

  get '/e/:slug/cohosts' do
    @event = event_from_params
    event_admins_only!
    erb :'events/cohosts'
  end

  post '/e/:slug/cohostships/:cohostship_id' do
    @event = event_from_params
    event_admins_only!
    @cohostship = @event.cohostships.find(params[:cohostship_id]) || not_found
    # Featuring places the event in the cohost organisation's carousels
    params[:cohostship].delete(:featured) if params[:cohostship] && !organisation_admins_or_event_managers?(@cohostship.organisation)
    if @cohostship.update_attributes(mass_assigning(params[:cohostship], Cohostship))
      redirect "/e/#{@event.slug}/cohosts"
    else
      flash.now[:error] = 'There was an error saving the cohost.'
      erb :'events/cohosts'
    end
  end

  get '/e/:slug/ticket_types' do
    @event = event_from_params
    event_admins_only!
    erb :'events/ticket_types'
  end

  get '/e/:slug/notes' do
    @event = event_from_params
    event_admins_only!
    partial :'events/notes'
  end

  post '/e/:slug/notes' do
    @event = event_from_params
    event_admins_only!
    @event.set(notes: params[:notes])
    200
  end

  post '/e/:slug/resend_feedback_email/:account_id' do
    @event = event_from_params
    event_admins_only!
    @event.send_feedback_requests(params[:account_id])
    flash[:notice] = 'The feedback email was resent.'
    redirect back
  end

  post '/e/:slug/resend_all_feedback_emails' do
    @event = event_from_params
    event_admins_only!
    @event.send_feedback_requests(:all, true)
    flash[:notice] = 'Feedback emails are being sent to all eligible attendees.'
    redirect back
  end

  get '/e/:slug/discount_codes' do
    @event = event_from_params
    event_admins_only!
    @discount_codes = @event.discount_codes
    @scope = "event_id=#{@event.id}"
    erb :'discount_codes/discount_codes'
  end

  post '/e/:slug/event_sessions/new' do
    @event = event_from_params
    event_admins_only!
    @event.event_sessions.create(mass_assigning(params[:event_session], EventSession))
    redirect back
  end

  post '/e/:slug/event_sessions/destroy' do
    @event = event_from_params
    event_admins_only!
    @event.event_sessions.find(params[:event_session_id]).try(:destroy)
    redirect back
  end

  get '/e/:slug/hide_from_homepage' do
    @event = event_from_params
    event_admins_only!
    partial :'events/hide_from_homepage', locals: { event: @event, block_edit: params[:block_edit] }
  end

  post '/e/:slug/do_hide_from_homepage' do
    @event = event_from_params
    event_admins_only!
    @event.set(hidden_from_homepage: true)
    200
  end

  post '/e/:slug/unhide_from_homepage' do
    @event = event_from_params
    event_admins_only!
    @event.set(hidden_from_homepage: false)
    200
  end
end
