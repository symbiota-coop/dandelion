Dandelion::App.controller do
  get '/events', provides: %i[html ics] do
    @events = Event.live.public.legit
    @from = params[:from] ? Date.parse(params[:from]) : Date.today
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order('start_time asc')
    @events = if params[:q]
                @events.and(:id.in => Event.all.or(
                  { name: /#{::Regexp.escape(params[:q])}/i },
                  { description: /#{::Regexp.escape(params[:q])}/i }
                ).pluck(:id))
              else
                @events.and(:organisation_id.in => Organisation.and(paid_up: true).pluck(:id))
              end
    @events = @events.and(:id.in => EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id)) if params[:event_tag_id]
    %i[organisation activity local_group].each do |r|
      @events = @events.and("#{r}_id": params[:"#{r}_id"]) if params[:"#{r}_id"]
    end
    @events = @events.online if params[:online]
    @events = @events.in_person if params[:in_person]
    content_type = (parts = URI(request.url).path.split('.')
                    parts.length == 2 ? parts.last.to_sym : :html)
    case content_type
    when :html
      @events = @events.future(@from)
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
      @events = @events.current(3.months.ago)
      cal = RiCal.Calendar do |rcal|
        rcal.add_x_property('X-WR-CALNAME', 'Dandelion')
        @events.each do |event|
          rcal.event do |revent|
            revent.summary = (event.start_time.to_date == event.end_time.to_date ? event.name : "#{event.name} starts")
            revent.dtstart = (event.start_time.to_date == event.end_time.to_date ? event.start_time : event.start_time.to_date)
            revent.dtend = (event.start_time.to_date == event.end_time.to_date ? event.end_time : event.start_time.to_date)
            revent.location = event.location
            revent.description = %(#{ENV['BASE_URI']}/events/#{event.id})
            revent.uid = event.id.to_s
          end
        end
      end
      cal.export
    end
  end

  get '/events/new' do
    sign_in_required!(r: '/accounts/new?list_an_event=1')
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
    @event.time_zone = current_account.time_zone
    @event.location = 'Online'
    @event.feedback_questions = 'Comments/suggestions'
    @event.affiliate_credit_percentage = @event.organisation.affiliate_credit_percentage
    @event.currency = @event.organisation.currency
    @event.suggested_donation = 0
    @event.coordinator = current_account
    @event.refund_deleted_orders = true
    @event.include_in_parent = true if organisation_admin?(@event.organisation)
    erb :'events/build'
  end

  post '/events/new' do
    sign_in_required!
    @event = Event.new(mass_assigning(params[:event], Event))
    @event.account = current_account
    @event.last_saved_by = current_account
    if @event.save
      redirect "/events/#{@event.id}?created=1"
    else
      flash.now[:error] = 'There was an error saving the event'
      erb :'events/build'
    end
  end

  get '/o/:slug/events/quick' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @event = @organisation.events.build
    erb :'events/quick'
  end

  post '/o/:slug/events/quick' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found

    account_hash = { name: params[:event][:email], email: params[:event][:email] }
    @account = if account_hash[:email] && (account = Account.find_by(email: account_hash[:email].downcase))
                 account
               else
                 Account.new(mass_assigning(account_hash, Account))
               end

    successful_update_or_save = if @account.persisted?
                                  @account.update_attributes(mass_assigning(Hash[account_hash.map { |k, v| [k, v] if v }.compact], Account))
                                else
                                  @account.save
                                end

    if successful_update_or_save
      @event = @organisation.events.build(mass_assigning(params[:event], Event))
      @event.account = @account
      @event.last_saved_by = @account
      @event.quick_create = true
      if @event.save
        redirect "/events/#{@event.id}"
      else
        flash.now[:error] = 'There was an error saving the event'
        erb :'events/quick'
      end
    else
      flash.now[:error] = 'There was an error creating an account'
      erb :'events/quick'
    end
  end

  get '/e/:slug' do
    @event = Event.find_by(slug: params[:slug]) || not_found
    redirect "/events/#{@event.id}"
  end

  get '/events/:id', provides: %i[html ics json] do
    session[:return_to] = request.url
    @event = Event.find(params[:id]) || not_found
    @order = (Order.find(params[:order_id]) || not_found) if params[:order_id]
    @og_desc = when_details(@event)
    kick! unless @event.organisation
    event_admins_only! if @event.draft?
    @title = @event.name
    @organisation = @event.organisation
    if @order && params[:success]
      @ga_transaction = { id: @order.id.to_s, affiliation: @event.organisation.name, revenue: (@order.value || 0), currency: @order.currency }
      @ga_items = @order.tickets.map do |ticket|
        { id: ticket.id.to_s, name: "#{ticket.event.name}: #{ticket.ticket_type.try(:name) || 'Complementary'}", price: (ticket.discounted_price || 0), quantity: 1 }
      end
      @pixel_purchase = { value: (@order.value || 0), currency: @order.currency }
    end
    if params[:cohost] && (cohost = Organisation.find_by(slug: params[:cohost])) && (cohostship = @event.cohostships.find_by(organisation: cohost)) && cohostship.image
      @event_image = cohostship.image
      @og_image = cohostship.image.url
    elsif @event.image
      @event_image = @event.image
      @og_image = @event.image.url
    elsif @event.organisation && @event.organisation.image
      @og_image = @event.organisation.image.url
    end
    case content_type
    when :html
      @hide_right_nav = true

      if @event.posts.empty?
        post = @event.posts.create!(subject: "Chat for #{@event.name}", account: @event.account)
        post.comments.create!(account: @event.account)
      end

      if params[:ticket_form_only]
        partial :'events/purchase', layout: :minimal
      else
        erb :'events/event'
      end
    when :json
      {
        name: @event.name,
        date: @event.start_time.to_date.to_s(:db),
        activity: ("#{@event.activity.name} (#{@event.activity_id})" if @event.activity),
        coordinator: ("#{@event.coordinator.name} (#{@event.coordinator_id})" if @event.coordinator),
        order_count: @event.orders.count,
        discounted_ticket_revenue: @event.discounted_ticket_revenue.cents.to_f / 100,
        organisation_discounted_ticket_revenue: @event.organisation_discounted_ticket_revenue.cents.to_f / 100,
        donation_revenue: @event.donation_revenue.cents.to_f / 100,
        organisation_revenue_share: @event.organisation_revenue_share
      }.to_json
    when :ics
      event = @event
      cal = RiCal.Calendar do |rcal|
        rcal.event do |revent|
          revent.summary = (event.start_time.to_date == event.end_time.to_date ? event.name : "#{event.name} starts")
          revent.dtstart = (event.start_time.to_date == event.end_time.to_date ? event.start_time : event.start_time.to_date)
          revent.dtend = (event.start_time.to_date == event.end_time.to_date ? event.end_time : event.start_time.to_date)
          revent.location = event.location
          revent.description = %(#{ENV['BASE_URI']}/events/#{event.id})
          revent.uid = event.id.to_s
        end
      end
      cal.export
    end
  end

  get '/events/:id/stats_row' do
    @event = Event.find(params[:id]) || not_found
    @organisation = params[:organisation_id] ? Organisation.find(params[:organisation_id]) : nil
    event_admins_only!
    cp(:'events/event_stats_row', locals: { event: @event }, key: "/events/#{@event.id}/stats_row?timezone=#{Time.zone.name}#{"&organisation_id=#{@organisation.id}" if @organisation}")
  end

  get '/events/:id/edit' do
    @event = Event.find(params[:id]) || not_found
    kick! unless @event.organisation
    event_admins_only!
    erb :'events/build'
  end

  post '/events/:id/edit' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.last_saved_by = current_account
    if @event.update_attributes(mass_assigning(params[:event], Event))
      flash[:notice] = 'The event was saved.'
      redirect "/events/#{@event.id}/edit"
    else
      flash.now[:error] = 'There was an error saving the event.'
      erb :'events/build'
    end
  end

  get '/events/:id/destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.send_destroy_notification(current_account)
    @event.destroy!
    flash[:notice] = 'The event was deleted.'
    redirect "/o/#{@event.organisation.slug}/events"
  end

  get '/events/:id/duplicate' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/duplicate'
  end

  post '/events/:id/duplicate' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    duplicated_event = @event.duplicate!(current_account)
    flash[:notice] = 'Event duplicated as a draft'
    redirect "/events/#{duplicated_event.id}/edit"
  end

  get '/events/:id/check_in' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/check_in'
  end

  get '/events/:id/check_in_toggle/:ticket_id' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    ticket = @event.tickets.find(params[:ticket_id])
    partial :'events/check_in_toggle', locals: { ticket: ticket }
  end

  post '/events/:id/check_in/:ticket_id' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    ticket = @event.tickets.find(params[:ticket_id])
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
        ticket.set(checked_in: nil)
      end
      ticket.account.name
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
                 .gsub('%recipient.firstname%', current_account.firstname)
                 .gsub('%recipient.token%', current_account.sign_in_token)
    Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
  end

  get '/orders/:id', provides: [:html, :pdf] do
    @order = Order.find(params[:id])
    @event = @order.event
    halt unless admin? || (current_account && @order.account_id == current_account.id)
    event = @event
    order = @order
    account = current_account
    content = ERB.new(File.read(Padrino.root('app/views/emails/tickets.erb'))).result(binding)
                 .gsub('%recipient.firstname%', current_account.firstname)
                 .gsub('%recipient.token%', current_account.sign_in_token)
    case content_type
    when :html
      Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
    when :pdf
      order.tickets_pdf.render
    end
  end

  get '/orders/:id/send_tickets' do
    @order = Order.find(params[:id])
    @event = @order.event
    event_admins_only!
    @order.send_tickets
    flash[:notice] = 'The tickets for the order were resent.'
    redirect back
  end

  post '/events/:id/waitship/new' do
    @event = Event.find(params[:id]) || not_found

    if ENV['RECAPTCHA_SECRET_KEY']
      agent = Mechanize.new
      captcha_response = JSON.parse(agent.post('https://www.google.com/recaptcha/api/siteverify', { secret: ENV['RECAPTCHA_SECRET_KEY'], response: params['g-recaptcha-response'] }).body)
      unless captcha_response['success'] == true
        flash[:error] = "Our systems think you're a bot. Please email contact@dandelion.earth if you keep having trouble."
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
    if if @account.persisted?
         @account.update_attributes(mass_assigning(Hash[account_hash.map { |k, v| [k, v] if v }.compact], Account))
       else
         @account.save
       end
      waitship = @event.waitships.create(account: @account)
      if waitship.persisted?
        redirect "/events/#{@event.id}?added_to_waitlist=true"
      else
        flash[:error] = waitship.errors.full_messages.join('; ')
        redirect "/events/#{@event.id}"
      end
    else
      flash[:error] = @account.errors.full_messages.join('; ')
      redirect "/events/#{@event.id}"
    end
  end

  get '/events/:id/tickets', provides: %i[html csv pdf] do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @tickets = if params[:ticket_type_id]
                 @event.ticket_types.find(params[:ticket_type_id]).tickets
               elsif params[:ticket_group_id]
                 @event.ticket_groups.find(params[:ticket_group_id]).tickets
               else
                 @event.tickets
               end
    if params[:q]
      @tickets = @tickets.and(:id.in =>
        Ticket.collection.aggregate([
                                      { '$addFields' => { 'id' => { '$toString' => '$_id' } } },
                                      { '$match' => { 'id' => { '$regex' => /#{::Regexp.escape(params[:q])}/i } } }
                                    ]).pluck(:id) +
        Ticket.and(
          :account_id.in => Account.all.or(
            { name: /#{::Regexp.escape(params[:q])}/i },
            { email: /#{::Regexp.escape(params[:q])}/i }
          ).pluck(:id)
        ).pluck(:id))
    end
    case content_type
    when :html
      erb :'events/tickets'
    when :csv
      CSV.generate do |csv|
        csv << %w[name email ordered_for_name ordered_for_email ticket_type price created_at]
        @tickets.each do |ticket|
          csv << [
            ticket.account.name,
            ticket_email_viewer?(ticket) ? ticket.account.email : '',
            ticket.name,
            ticket_email_viewer?(ticket) ? ticket.email : '',
            ticket.ticket_type.try(:name),
            m(ticket.discounted_price || 0, ticket.order ? ticket.order.currency : ticket.event.currency),
            ticket.created_at.to_s(:db)
          ]
        end
      end
    when :pdf
      @tickets = @tickets.sort_by { |ticket| ticket.account.name }
      Prawn::Document.new(page_layout: :landscape) do |pdf|
        pdf.font "#{Padrino.root}/app/assets/fonts/circular-ttf/CircularStd-Book.ttf"
        pdf.table([%w[name email ordered_for_name ordered_for_email ticket_type price created_at]] +
            @tickets.map do |ticket|
              [
                ticket.account.name_transliterated,
                ticket_email_viewer?(ticket) ? ticket.account.email : '',
                (I18n.transliterate(ticket.name) if ticket.name),
                ticket_email_viewer?(ticket) ? ticket.email : '',
                ticket.ticket_type.try(:name),
                m(ticket.discounted_price || 0, ticket.order ? ticket.order.currency : ticket.event.currency),
                ticket.created_at.to_s(:db)
              ]
            end)
      end.render
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
                                  @account.update_attributes(mass_assigning(Hash[account_hash.map { |k, v| [k, v] if v }.compact], Account))
                                else
                                  @account.save
                                end
    if successful_update_or_save
      ticket = @account.tickets.create(event: @event, ticket_type: params[:ticket][:ticket_type_id], price: params[:ticket][:price], complementary: true)
      if ticket.persisted?
        ticket.send_ticket
        redirect "/events/#{@event.id}/tickets"
      else
        flash[:error] = ticket.errors.full_messages.join('; ')
        redirect "/events/#{@event.id}/tickets"
      end
    else
      flash[:error] = @account.errors.full_messages.join('; ')
      redirect "/events/#{@event.id}/tickets"
    end
  end

  get '/events/:id/orders/:order_id/payment_completed', provides: :json do
    @event = Event.find(params[:id]) || not_found
    @order = @event.orders.find(params[:order_id])
    @event.organisation.check_seeds_account if @order.seeds_secret && @event.organisation.seeds_username
    @event.organisation.check_xdai_account if @order.xdai_secret && @event.organisation.xdai_address
    { id: @order.id.to_s, payment_completed: @order.payment_completed }.to_json
  end

  get '/events/:id/orders/:order_id/destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.orders.find(params[:order_id]).try(:destroy)
    redirect back
  end

  get '/events/:id/orders/:order_id/restore_and_complete' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.orders.deleted.find(params[:order_id]).restore_and_complete
    redirect back
  end

  get '/events/:id/tickets/:ticket_id/destroy' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.tickets.find(params[:ticket_id]).try(:destroy)
    redirect back
  end

  get '/events/:id/orders', provides: %i[html csv pdf] do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @orders = @event.orders
    @orders =  @orders.deleted if params[:deleted]
    @orders =  @orders.complete if params[:complete]
    @orders =  @orders.incomplete if params[:incomplete]
    if params[:q]
      @orders = @orders.and(:account_id.in => Account.all.or(
        { name: /#{::Regexp.escape(params[:q])}/i },
        { email: /#{::Regexp.escape(params[:q])}/i }
      ).pluck(:id))
    end

    case content_type
    when :html
      erb :'events/orders'
    when :csv
      CSV.generate do |csv|
        csv << %w[name email value opt_in_organisation opt_in_facilitator created_at]
        @orders.each do |order|
          csv << [
            order.account ? order.account.name : '',
            if order_email_viewer?(order)
              order.account ? order.account.email : ''
            else
              ''
            end,
            m((order.value || 0), order.currency),
            order.opt_in_organisation,
            order.opt_in_facilitator,
            order.created_at.to_s(:db)
          ]
        end
      end
    when :pdf
      @orders = @orders.sort_by { |order| order.account.name }
      Prawn::Document.new do |pdf|
        pdf.font "#{Padrino.root}/app/assets/fonts/circular-ttf/CircularStd-Book.ttf"
        pdf.table([%w[name email value created_at]] +
            @orders.map do |order|
              [
                order.account.name_transliterated,
                if order_email_viewer?(order)
                  order.account ? order.account.email : ''
                else
                  ''
                end,
                m((order.value || 0), order.currency),
                order.created_at.to_s(:db)
              ]
            end)
      end.render
    end
  end

  get '/events/:id/donations' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @donations = @event.donations
    if params[:q]
      @donations = @donations.and(:account_id.in => Account.all.or(
        { name: /#{::Regexp.escape(params[:q])}/i },
        { email: /#{::Regexp.escape(params[:q])}/i }
      ).pluck(:id))
    end
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
    if params[:q]
      @waitships = @waitships.and(:account_id.in => Account.all.or(
        { name: /#{::Regexp.escape(params[:q])}/i },
        { email: /#{::Regexp.escape(params[:q])}/i }
      ).pluck(:id))
    end
    erb :'events/waitlist'
  end

  get '/events/:id/facilitators' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    erb :'events/facilitators'
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
    @event.tickets.and(account: current_account).update_all(show_attendance: nil)
    200
  end

  get '/events/:id/show_attendance' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    @event.tickets.and(account: current_account).update_all(show_attendance: true)
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
    event_admins_only!
    @event.cohostships.create(organisation_id: params[:cohostship][:organisation_id])
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
    @event.tickets.and(account: current_account).update_all(subscribed_discussion: true)
    request.xhr? ? 200 : redirect("/events/#{@event.id}")
  end

  get '/events/:id/unsubscribe_discussion' do
    sign_in_required!
    @event = Event.find(params[:id]) || not_found
    @event.tickets.and(account: current_account).update_all(subscribed_discussion: false)
    request.xhr? ? 200 : redirect("/events/#{@event.id}")
  end

  get '/events/:id/resend_feedback_email/:account_id' do
    @event = Event.find(params[:id]) || not_found
    event_admins_only!
    @event.send_feedback_requests(account_id: params[:account_id])
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

  get '/events/:id/orders/:order_id/ticketholders/:ticket_id/:f' do
    @event = Event.find(params[:id]) || not_found
    @order = @event.orders.find(params[:order_id]) || not_found
    @ticket = @order.tickets.find(params[:ticket_id])
    partial :"events/ticketholder_#{params[:f]}", locals: { ticket: @ticket }
  end

  post '/events/:id/orders/:order_id/ticketholders/:ticket_id/:f' do
    @event = Event.find(params[:id]) || not_found
    @order = @event.orders.find(params[:order_id]) || not_found
    @ticket = @order.tickets.find(params[:ticket_id]) || not_found
    @ticket.send(:"#{params[:f]}=", params[params[:f]])
    @ticket.save
    200
  end
end
