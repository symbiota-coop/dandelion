Dandelion::App.controller do
  get '/facilitators' do
    @event_tags = EventTag.all
    erb :'events/facilitators'
  end

  get '/events', provides: %i[html ics] do
    @events = Event.live.public.browsable
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @events = case params[:order]
              when 'created_at'
                @events.order('created_at desc')
              else
                @events.order('start_time asc')
              end
    @events = if params[:q]
                @events.and(:id.in => search_events(params[:q]).pluck(:id))
              else
                @events
              end
    if params[:near] && (result = Geocoder.search(params[:near]).first)
      bounds = nil
      if result.respond_to?(:boundingbox) && result.boundingbox
        bounds = true
        south, north, west, east = result.boundingbox.map(&:to_f)
      elsif result.respond_to?(:bounds) && result.bounds
        bounds = true
        if ['uk', 'united kingdom'].include?(params[:near].downcase)
          south = 49.6740000
          west = -14.0155170
          north = 61.0610000
          east = 2.0919117
        else
          south, west, north, east = result.bounds.map(&:to_f)
        end
      end
      unless bounds
        # Create a 10km x 10km bounding box around the geocoded location
        km = 10
        lat, lng = result.coordinates
        # Approximate degrees per kilometer (varies by latitude, but good enough for a 10km box)
        lat_offset = (km / 2) * 0.009 # ~1km = 0.009 degrees latitude
        lng_offset = (km / 2) * 0.009 / Math.cos(lat * Math::PI / 180) # Adjust for longitude compression at this latitude

        south = lat - lat_offset
        north = lat + lat_offset
        west = lng - lng_offset
        east = lng + lng_offset
      end
      @bounding_box = [[west, south], [east, north]]
      @events = @events.and(coordinates: { '$geoWithin' => { '$box' => @bounding_box } })
    end
    @events = @events.and(:id.in => EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id)) if params[:event_tag_id]
    %i[organisation activity local_group].each do |r|
      @events = @events.and("#{r}_id": params[:"#{r}_id"]) if params[:"#{r}_id"]
    end
    unless params[:online] && params[:in_person]
      @events = @events.online if params[:online]
      @events = @events.in_person if params[:in_person]
    end
    content_type = (parts = URI(request.url).path.split('.')
                    parts.length == 2 ? parts.last.to_sym : :html)
    case content_type
    when :html
      @events = @events.future(@from)
      @events = @events.and(:start_time.lt => @to + 1) if @to
      if params[:order] == 'random'
        event_ids = @events.pluck(:id)
        @events = @events.collection.aggregate([
                                                 { '$match' => { '_id' => { '$in' => event_ids } } },
                                                 { '$sample' => { size: event_ids.length } }
                                               ]).map do |hash|
          Event.new(hash.select { |k, _v| Event.fields.keys.include?(k.to_s) })
        end
      end
      if request.xhr?
        if params[:display] == 'map'
          @lat = params[:lat]
          @lng = params[:lng]
          @zoom = params[:zoom]
          @south = params[:south]
          @west = params[:west]
          @north = params[:north]
          @east = params[:east]
          box = [[@west.to_f, @south.to_f], [@east.to_f, @north.to_f]]

          @events = @events.and(coordinates: { '$geoWithin' => { '$box' => box } }) unless @events.empty?
          @points_count = @events.count
          @points = @events.to_a
          partial :'maps/map', locals: { stem: '/events', dynamic: true, points: @points, points_count: @points_count, centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom }
        else
          partial :'events/events'
        end
      else
        erb :'events/events'
      end
    when :ics
      @events = @events.current.limit(500)
      cal = Icalendar::Calendar.new
      cal.append_custom_property('X-WR-CALNAME', 'Dandelion')
      @events.each do |event|
        cal.event do |e|
          e.summary = (event.start_time.to_date == event.end_time.to_date ? event.name : "#{event.name} starts")
          e.dtstart = (event.start_time.to_date == event.end_time.to_date ? event.start_time.utc.strftime('%Y%m%dT%H%M%SZ') : Icalendar::Values::Date.new(event.start_time.to_date))
          e.dtend = (event.start_time.to_date == event.end_time.to_date ? event.end_time.utc.strftime('%Y%m%dT%H%M%SZ') : nil)
          e.location = event.location
          e.description = %(#{ENV['BASE_URI']}/events/#{event.id})
          e.uid = event.id.to_s
        end
      end
      cal.to_ical
    end
  end

  get '/events/my' do
    sign_in_required!
    erb :'events/my'
  end

  get '/events/new' do
    sign_in_required!(redirect_url: '/accounts/new?list_an_event=1')
    @draft = current_account.drafts.find(params[:draft_id]) if params[:draft_id]
    @event = Event.new
    if params[:organisation_id]
      @event.organisation = Organisation.find(params[:organisation_id]) || not_found
    elsif params[:activity_id]
      @event.activity = Activity.find(params[:activity_id]) || not_found
      @event.organisation = @event.activity.organisation
    elsif params[:local_group_id]
      @event.local_group = LocalGroup.find(params[:local_group_id]) || not_found
      @event.organisation = @event.local_group.organisation
    end
    unless @event.organisation
      if current_account.organisations.count == 0
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
      @event.affiliate_credit_percentage = @event.organisation.affiliate_credit_percentage
      @event.currency = @event.organisation.currency
      @event.suggested_donation = 0
      @event.coordinator = current_account
      @event.refund_deleted_orders = true
      @event.opt_in_organisation = true
      @event.opt_in_facilitator = true
      @event.ask_hear_about = true
      @event.include_in_parent = true if organisation_admin?(@event.organisation)
      erb :'events_build/build'
    end
  end

  post '/events/new' do
    sign_in_required!
    @event = Event.new(mass_assigning(params[:event], Event))
    unless @event.organisation
      flash[:error] = 'There was an error saving the event'
      if current_account.organisations.count == 0
        redirect '/o/new'
      else
        redirect '/events'
      end
    end
    @event.account = current_account
    @event.last_saved_by = current_account
    if @event.save
      @event.set(locked: true) if !@event.organisation.payment_method? && @event.paid_tickets?
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
    @event = Event.find(params[:id]) || not_found
    if @event.slug
      redirect request.url.gsub('/events/', '/e/').gsub(params[:id], @event.slug)
    else
      redirect request.url.gsub('/events/', '/e/')
    end
  end

  get '/e/:slug', provides: %i[html ics json] do
    session[:via] = params[:via] if params[:via]
    session[:return_to] = request.url
    @event = Event.find_by(slug: params[:slug])
    if !@event && params[:slug] =~ /[A-Z]/
      @event = Event.find_by(slug: params[:slug].downcase)
      redirect "/e/#{@event.slug}" if @event
    end
    unless @event
      id = params[:slug]
      @event = Event.find(id) || not_found
      redirect request.url.gsub(id, @event.slug) if @event.slug
    end
    @order = Order.find(params[:order_id]) || not_found if params[:order_id]
    @og_desc = when_details(@event)
    kick! unless @event.organisation
    kick!(redirect_url: "/o/#{@event.organisation.slug}/events") if @event.locked? && !event_admin?
    @title = @event.name
    @organisation = @event.organisation
    @event.check_oc_event if @order && params[:success] && !@order.payment_completed && @event.oc_slug
    cohostship = nil
    if params[:cohost] && (cohost = Organisation.find_by(slug: params[:cohost])) && (cohostship = @event.cohostships.find_by(organisation: cohost)) && cohostship.image
      @event_image = cohostship.image.thumb('1920x1920')
      @og_image = cohostship.image.encode('jpg', '-quality 90').thumb('1200x630').url
    elsif @event.image
      @event_image = @event.image.thumb('1920x1920')
      @og_image = @event.image.encode('jpg', '-quality 90').thumb('1200x630').url
    elsif @event.organisation && @event.organisation.image
      @og_image = @event.organisation.image.encode('jpg', '-quality 90').thumb('1200x630').url
    end
    @event_video = @event.video if @event.video
    @event_video = cohostship.video if cohostship && cohostship.video
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

  get '/events/:id/progress' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    partial :'events/progress', locals: { event: @event, full_width: params[:full_width] }
  end

  get '/events/:id/stats_row' do
    @event = Event.unscoped.find(params[:id]) || not_found
    @organisation = Organisation.find(params[:organisation_id]) || not_found
    event_admins_only!
    cp(:'events/event_stats_row', locals: { event: @event, organisation: @organisation, event_revenue_admin: event_revenue_admin? }, key: "/events/#{@event.id}/stats_row?timezone=#{@event.start_time.strftime('%Z')}&organisation_id=#{@organisation.id}&event_revenue_admin=#{event_revenue_admin? ? 1 : 0}")
  end

  get '/events/:id/edit' do
    @event = Event.unscoped.find(params[:id]) || not_found
    redirect "/e/#{@event.slug}/edit"
  end

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
      @event.set(locked: true) if !@event.organisation.payment_method? && @event.paid_tickets?
      flash[:notice] = 'The event was saved.'
      redirect "/e/#{@event.slug}/edit"
    else
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
    @event.update_attribute(:refund_deleted_orders, false) if params[:no_refunds]
    @event.send_destroy_notification(current_account)
    @event.destroy
    flash[:notice] = 'The event was deleted.'
    redirect "/o/#{@event.organisation.slug}/events"
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
      flash[:notice] = 'Event duplicated and locked'
      redirect "/e/#{duplicated_event.slug}/edit"
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
    event = @event
    account = current_account
    order = @event.orders.new
    order.tickets.new(ticket_type: @event.ticket_types.first)
    order.tickets.new(ticket_type: @event.ticket_types.first)
    order.account = account
    content = ERB.new(File.read(Padrino.root('app/views/emails/tickets.erb'))).result(binding)
                 .gsub('%recipient.token%', current_account.sign_in_token)
    Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
  end

  get '/events/:id/reminder_email' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/reminder_email'
  end

  get '/events/:id/reminder_email_preview' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    event = @event
    content = ERB.new(File.read(Padrino.root('app/views/emails/reminder.erb'))).result(binding)
                 .gsub('%recipient.firstname%', current_account.firstname)
                 .gsub('%recipient.token%', current_account.sign_in_token)
    Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
  end

  get '/events/:id/feedback_request_email' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/feedback_request_email'
  end

  get '/events/:id/feedback_request_email_preview' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    event = @event
    content = ERB.new(File.read(Padrino.root('app/views/emails/feedback.erb'))).result(binding)
                 .gsub('%recipient.firstname%', current_account.firstname)
                 .gsub('%recipient.token%', current_account.sign_in_token)
                 .gsub('%recipient.id%', current_account.id)
    Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
  end

  post '/events/:id/waitship/new' do
    @event = Event.find(params[:id]) || not_found

    if ENV['RECAPTCHA_SECRET_KEY']
      agent = Mechanize.new
      captcha_response = JSON.parse(agent.post(ENV['RECAPTCHA_VERIFY_URL'], { secret: ENV['RECAPTCHA_SECRET_KEY'], response: params['g-recaptcha-response'] }).body)
      unless captcha_response['success'] == true
        flash[:error] = "Our systems think you're a bot. Please try a different device or browser, or email #{ENV['CONTACT_EMAIL']} if you keep having trouble."
        redirect(back)
      end
    end

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
      ticket = @account.tickets.create(event: @event, ticket_type: params[:ticket][:ticket_type_id], price: params[:ticket][:price], complementary: true)
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
    @stripe_charges = @event.stripe_charges.and(:balance_transaction.ne => nil)
    @stripe_charges = @stripe_charges.and(:account_id.in => search_accounts(params[:q]).pluck(:id)) if params[:q]

    if request.xhr?
      partial :'events/stripe_charges_table', locals: { stripe_charges: @stripe_charges, show_emails: event_email_viewer? }
    else
      erb :'events/stripe_charges'
    end
  end

  get '/events/:id/donations' do
    @event = Event.unscoped.find(params[:id]) || not_found
    event_admins_only!
    @donations = @event.donations
    @donations = @donations.and(:account_id.in => search_accounts(params[:q]).pluck(:id)) if params[:q]
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
    @waitships = @event.waitships
    @waitships = @waitships.and(:account_id.in => search_accounts(params[:q]).pluck(:id)) if params[:q]
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

  get '/events/:id/pmails' do
    @event = Event.find(params[:id]) || not_found
    @_organisation = @event.organisation
    event_admins_only!
    @pmails = @event.pmails_as_mailable.order('created_at desc').page(params[:page])
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

  get '/events/:id/questions' do
    partial :'events/questions', locals: { questions: params[:questions] }
  end

  get '/events/:id/feedback_questions' do
    partial :'events/feedback_questions', locals: { questions: params[:questions] }
  end
end
