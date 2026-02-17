Dandelion::App.controller do
  get '/events', provides: %i[html ics json], prefetch: true do
    @events = Event.live.publicly_visible.browsable
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil

    content_type = (parts = URI(request.url).path.split('.')
                    parts.length == 2 ? parts.last.to_sym : :html)

    @events = apply_events_order(@events)
    @events = apply_geo_filter(@events)
    @events = @events.and(:id.in => EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id)) if params[:event_tag_id]
    %i[organisation activity local_group].each do |r|
      @events = @events.and("#{r}_id": params[:"#{r}_id"]) if params[:"#{r}_id"]
    end
    @events = apply_online_in_person_filter(@events)
    @events = @events.and(hidden_from_homepage: false) if params[:home]
    @events = @events.and(has_image: true) if params[:images]
    case content_type
    when :html
      @events = @events.without_heavy_fields
      @events = @events.future(@from)
      @events = @events.and(:start_time.lt => @to + 1) if @to
      @events = @events.and(:id.in => Event.search(params[:q], @events).pluck(:id)) if params[:q]
      @events = apply_random_or_trending_order(@events, @from)
      request.xhr? ? partial(:'events/events') : erb(:'events/events')
    when :json
      @events = @events.future(@from)
      @events = @events.and(:start_time.lt => @to + 1) if @to
      @events = @events.and(locked: false)
      @events = @events.and(:id.in => Event.search(params[:q], @events).pluck(:id)) if params[:q]
      map_json(@events)
    when :ics
      @events = @events.without_heavy_fields
      @events = @events.future
      @events = @events.and(:id.in => Event.search(params[:q], @events).pluck(:id)) if params[:q]
      @events = @events.limit(500)
      build_events_ical(@events, 'Dandelion')
    end
  end

  get '/events/my' do
    sign_in_required!
    erb :'events/my'
  end

  get '/events/new' do
    sign_in_required!(redirect_url: '/accounts/new?list_an_event=1')
    @event = Event.new
    if params[:draft_id] && (@draft = current_account.drafts.find(params[:draft_id]))
      @event.organisation = JSON.parse(@draft.json)['organisation_id']
    elsif params[:organisation_id]
      @event.organisation = Organisation.find(params[:organisation_id]) || not_found
    elsif params[:activity_id]
      @event.activity = Activity.find(params[:activity_id]) || not_found
      @event.organisation = @event.activity.organisation
    elsif params[:local_group_id]
      @event.local_group = LocalGroup.find(params[:local_group_id]) || not_found
      @event.organisation = @event.local_group.organisation
    end
    unless @event.organisation
      if current_account.organisations.empty?
        redirect '/o/new'
      else
        redirect '/events'
      end
    end

    if Padrino.env == :production && !@event.organisation.stripe_client_id && @event.organisation.stripe_sk && !@event.organisation.stripe_connect_json
      @organisation = @event.organisation
      erb :'events/stripe_connect'
    elsif @event.organisation.contribution_required
      redirect "/o/#{@event.organisation.slug}/contribute"
    else
      @event.location = 'Online'
      @event.feedback_questions = 'Comments/suggestions'
      @event.currency = @event.organisation.currency
      @event.suggested_donation = 0
      @event.coordinator = current_account
      @event.refund_deleted_orders = true
      @event.opt_in_organisation = true
      @event.opt_in_facilitator = true
      @event.ask_hear_about = true
      erb :'events_build/build'
    end
  end

  post '/events/new' do
    sign_in_required!
    @event = Event.new(mass_assigning(params[:event], Event))
    unless @event.organisation
      flash[:error] = 'There was an error saving the event'
      if current_account.organisations.empty?
        redirect '/o/new'
      else
        redirect '/events'
      end
    end
    @event.account = current_account
    @event.last_saved_by = current_account
    if @event.save
      @event.lock! if !@event.organisation.payment_method? && @event.paid_tickets?
      redirect "/e/#{@event.slug}?created=1"
    else
      flash.now[:error] = 'There was an error saving the event'
      erb :'events_build/build'
    end
  end

  post '/events/draft' do
    sign_in_required!
    current_account.drafts.create(model: 'Event', name: params[:event][:name], url: request.referer, json: params[:event].to_json)
    200
  end

  get '/drafts/:id/destroy' do
    sign_in_required!
    draft = current_account.drafts.find(params[:id]) || not_found
    draft.destroy
    200
  end

  get '/events/:id', provides: %i[html ics json] do
    @event = Event.without_heavy_fields.find(params[:id]) || not_found
    if @event.slug
      redirect request.url.gsub('/events/', '/e/').gsub(params[:id], @event.slug)
    else
      redirect request.url.gsub('/events/', '/e/')
    end
  end

  get '/e/:slug', provides: %i[html ics json], prerender: true do
    session[:via] = params[:via] if params[:via]
    session[:return_to] = request.url
    @event = Event.without(:embedding).find_by(slug: params[:slug])
    if !@event && params[:slug] =~ /[A-Z]/
      @event = Event.without(:embedding).find_by(slug: params[:slug].downcase)
      redirect "/e/#{@event.slug}" if @event
    end
    unless @event
      id = params[:slug]
      @event = Event.without(:embedding).find(id) || not_found
      redirect request.url.gsub(id, @event.slug) if @event.slug
    end

    redirect @event.purchase_url if @event.minimal_only? && @event.purchase_url

    @order = Order.find(params[:order_id]) || not_found if params[:order_id]
    @og_desc = when_details(@event)
    kick! unless @event.organisation
    kick!(redirect_url: "/o/#{@event.organisation.slug}/events") if @event.locked? && !event_admin?
    @title = @event.name
    @organisation = @event.organisation
    @event.check_oc_event if @order && params[:success] && !@order.payment_completed && @event.oc_slug
    cohost = params[:cohost] && Organisation.find_by(slug: params[:cohost])
    image_source = @event.image_source(cohost)
    if image_source
      @event_image = image_source.image
      @event_image_width = image_source.image_width_unmagic
      @event_image_height = image_source.image_height_unmagic
      @og_image = image_source.image.encode('jpg', '-quality 90').thumb('1200x630').url
    elsif @event.organisation&.image
      @og_image = @event.organisation.image.encode('jpg', '-quality 90').thumb('1200x630').url
    end
    case content_type
    when :html
      @hide_right_nav = true

      if @event.posts.empty?
        post = @event.posts.create(subject: "Chat for #{@event.name}", account: @event.account)
        post.comments.create(account: @event.account) if post.persisted?
      end

      if params[:ticket_form_only]
        partial :'purchase/purchase', layout: :minimal
      else
        @body_class = 'greyed'
        erb :'events/event'
      end
    when :json
      {
        name: @event.name,
        start_date: @event.start_time.to_date.to_fs(:db_local),
        end_date: @event.end_time.to_date.to_fs(:db_local),
        activity: ("#{@event.activity.name} (#{@event.activity_id})" if @event.activity),
        event_coordinator: ("#{@event.coordinator.name} (#{@event.coordinator_id})" if @event.coordinator),
        carousel: @event.carousel_name,
        order_count: @event.orders.complete.count,
        discounted_ticket_revenue: @event.discounted_ticket_revenue.cents.to_f / 100,
        organisation_discounted_ticket_revenue: @event.organisation_discounted_ticket_revenue.cents.to_f / 100,
        donation_revenue: @event.donation_revenue.cents.to_f / 100,
        organisation_revenue_share: (@event.organisation_revenue_share if @event.revenue_sharer)
      }.to_json
    when :ics
      @event.ical.to_ical
    end
  end

  get '/event_sessions/:id', provides: %i[ics] do
    @event_session = EventSession.find(params[:id]) || not_found
    @event_session.ical.to_ical
  end

  post '/events/:id/purchase', provides: :json do
    @event = Event.find(params[:id]) || not_found
    @account = find_or_create_account_for_purchase(params[:detailsForm])
    halt 403 if @event.organisation.banned_emails_a.include?(@account.email)

    @order = create_order_with_tickets(params[:ticketForm], params[:detailsForm])
    process_payment(params[:detailsForm], params[:ticketForm])
  rescue Stripe::InvalidRequestError => e
    # Don't lock the event if the error is simply that the value is not high enough
    @order.event.lock! unless e.message&.include?('must add up to at least')
    @order.notify_of_failed_purchase(e)
    @order.destroy
    halt 400
  rescue StandardError => e
    Honeybadger.context({ order_id: @order.id }) if @order
    Honeybadger.notify(e)
    @order.try(:destroy)
    halt 400
  end

  get '/events/:id/edit' do
    @event = Event.unscoped.find(params[:id]) || not_found
    redirect "/e/#{@event.slug}/edit"
  end

  post '/events/:id/waitship/new' do
    @event = Event.find(params[:id]) || not_found

    validate_recaptcha

    email = params[:waitship][:email]
    account_hash = { name: params[:waitship][:name], email: params[:waitship][:email], password: Account.generate_password }
    @account = if (account = Account.find_by(email: email.try(:downcase)))
                 account
               else
                 Account.new(account_hash)
               end
    successful_update_or_save = if @account.persisted?
                                  @account.update_attributes(mass_assigning(account_hash.map { |k, v| [k, v] if v }.compact.to_h, Account))
                                else
                                  @account.save
                                end
    if successful_update_or_save
      waitship = @event.waitships.create(account: @account)
      if @event.waitships.find_by(account: @account)
        redirect "/e/#{@event.slug}?added_to_waitlist=true"
      else
        flash[:error] = waitship.errors.full_messages.join('; ')
        redirect "/e/#{@event.slug}"
      end
    else
      flash[:error] = @account.errors.full_messages.join('; ')
      redirect "/e/#{@event.slug}"
    end
  end

  get '/events/:id/attendees' do
    @event = Event.find(params[:id]) || not_found
    partial :'events/attendees'
  end

  get '/events/:id/hide_attendance' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    @event.tickets.complete.and(account: current_account).update_all(show_attendance: nil)
    200
  end

  get '/events/:id/show_attendance' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    @event.tickets.complete.and(account: current_account).update_all(show_attendance: true)
    200
  end

  get '/events/:id/subscribe_discussion' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    partial :'events/subscribe_discussion'
  end

  get '/events/:id/set_subscribe_discussion' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    @event.tickets.complete.and(account: current_account).update_all(subscribed_discussion: true)
    request.xhr? ? 200 : redirect("/e/#{@event.slug}")
  end

  get '/events/:id/unsubscribe_discussion' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    @event.tickets.complete.and(account: current_account).update_all(subscribed_discussion: false)
    request.xhr? ? 200 : redirect("/e/#{@event.slug}")
  end

  get '/events/:id/star' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    @event_star = @event.event_stars.find_by(account: current_account)
    partial :'events/star', locals: { event: @event, event_star: @event_star, block_edit: params[:block_edit] }
  end

  get '/events/:id/do_star' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    @event.event_stars.create(account: current_account)
    200
  end

  get '/events/:id/unstar' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    @event_star = @event.event_stars.find_by(account: current_account)
    @event_star.try(:destroy)
    200
  end

  get '/events/:id/questions' do
    partial :'questions/questions', locals: { questions: params[:questions], preview: true }
  end

  get '/events/:id/feedback_questions' do
    partial :'events/feedback_questions', locals: { questions: params[:questions] }
  end
end
