Dandelion::App.controller do
  get '/organisations', provides: %i[html json] do
    case content_type
    when :html
      @organisations = Organisation.and(:hidden.ne => true)
      @organisations = params[:order] == 'created_at' ? @organisations.order('created_at desc') : @organisations.order('followers_count desc')
      if params[:q]
        @organisations = @organisations.and(:id.in => Organisation.all.or(
          { name: /#{Regexp.escape(params[:q])}/i },
          { intro_text: /#{Regexp.escape(params[:q])}/i }
        ).pluck(:id))
      end
      @organisations = @organisations.and(:id.in => current_account.organisations_following.pluck(:id)) if current_account && params[:following]
      @organisations = @organisations.paginate(page: params[:organisations_page], per_page: 50)
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

          @organisations = @organisations.and(coordinates: { '$geoWithin' => { '$box' => box } }) unless @organisations.empty?
          @points_count = @organisations.count
          @points = @organisations.to_a
          partial :'maps/map', locals: { stem: '/organisations', dynamic: true, points: @points, points_count: @points_count, centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom }
        end
      else
        erb :'organisations/organisations'
      end
    when :json
      @organisations = Organisation.all.order('created_at desc')
      @organisations = @organisations.and(name: /#{Regexp.escape(params[:q])}/i) if params[:q]
      @organisations = @organisations.and(id: params[:id]) if params[:id]
      {
        results: @organisations.map { |organisation| { id: organisation.id.to_s, text: "#{organisation.name} (id:#{organisation.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/activities', provides: %i[html json] do
    @organisation = (Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found)
    @activities = @organisation.activities.order('name asc')
    @activities = @activities.and(name: /#{Regexp.escape(params[:q])}/i) if params[:q]
    @activities = @activities.and(id: params[:id]) if params[:id]
    case content_type
    when :html
      @activities = @activities.active
      if request.xhr?
        partial :'organisations/activities'
      else
        erb :'organisations/activities'
      end
    when :json
      {
        results: @activities.map { |activity| { id: activity.id.to_s, text: "#{activity.name} (id:#{activity.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/local_groups', provides: %i[html json] do
    @organisation = (Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found)
    @local_groups = @organisation.local_groups.order('name asc')
    @local_groups = @local_groups.and(name: /#{Regexp.escape(params[:q])}/i) if params[:q]
    @local_groups = @local_groups.and(id: params[:id]) if params[:id]
    case content_type
    when :html
      if request.xhr?
        partial :'organisations/local_groups'
      else
        erb :'organisations/local_groups'
      end
    when :json
      {
        results: @local_groups.map { |local_group| { id: local_group.id.to_s, text: "#{local_group.name} (id:#{local_group.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/news' do
    @organisation = (Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found)
    @pmails = @organisation.news
    if request.xhr?
      partial :'organisations/news'
    else
      erb :'organisations/news', layout: (params[:minimal] ? 'minimal' : nil)
    end
  end

  get '/o/:slug/news/latest' do
    @organisation = (Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found)
    @pmails = @organisation.news
    redirect "/pmails/#{@pmails.first.id}"
  end

  get '/o/new' do
    sign_in_required!
    @organisation = current_account.organisations.build(params[:organisation])
    erb :'organisations/build'
  end

  post '/o/new' do
    sign_in_required!
    @organisation = current_account.organisations.build(params[:organisation])
    @organisation.show_sign_in_link_in_ticket_emails = true
    @organisation.show_ticketholder_link_in_ticket_emails = true
    if @organisation.save
      redirect "/o/#{@organisation.slug}/edit?created=1&tab=2"
    else
      flash.now[:error] = 'There was an error saving the organisation.'
      erb :'organisations/build'
    end
  end

  get '/o/:slug' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @title = @organisation.name
    erb :'organisations/organisation'
  end

  get '/o/:slug/edit' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/build'
  end

  post '/o/:slug/edit' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    if @organisation.update_attributes(mass_assigning(params[:organisation], Organisation))
      flash[:notice] = 'The organisation was saved.'

      redirect(current_account.organisations.count == 1 ? "/o/#{@organisation.slug}" : "/o/#{@organisation.slug}/edit")
    else
      flash.now[:error] = 'There was an error saving the organisation.'
      erb :'organisations/build'
    end
  end

  get '/o/:slug/emails' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/emails'
  end

  post '/o/:slug/emails' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    if @organisation.update_attributes(mass_assigning(params[:organisation], Organisation))
      flash[:notice] = 'Your settings were saved.'
      redirect "/o/#{@organisation.slug}/emails"
    else
      flash.now[:error] = 'There was an error saving your settings.'
      erb :'organisations/emails'
    end
  end

  get '/o/:slug/banned_emails' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/banned_emails'
  end

  post '/o/:slug/banned_emails' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    if @organisation.update_attribute(:banned_emails, params[:organisation][:banned_emails])
      flash[:notice] = 'Your settings were saved.'
      redirect "/o/#{@organisation.slug}/banned_emails"
    else
      flash.now[:error] = 'There was an error saving your settings.'
      erb :'organisations/banned_emails'
    end
  end

  get '/o/:slug/events_block' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @events = @organisation.events_for_search(include_all_local_group_events: (true if params[:local_group_id])).future_and_current_featured
    @events = @events.and(monthly_donors_only: true) if params[:members_events]
    partial :'organisations/events_block'
  end

  get '/o/:slug/events', provides: %i[html ics json] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @events = @organisation.events_for_search(include_all_local_group_events: (true if params[:local_group_id]))
    @from = params[:from] ? Date.parse(params[:from]) : Date.today
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order('start_time asc')
    q_ids = []
    q_ids += search_events(params[:q]).pluck(:id) if params[:q]
    event_tag_ids = []
    event_tag_ids = EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id) if params[:event_tag_id]
    event_ids = (!q_ids.empty? && !event_tag_ids.empty? ? (q_ids & event_tag_ids) : (q_ids + event_tag_ids))
    @events = @events.and(:id.in => event_ids) unless event_ids.empty?
    @events = @events.and(local_group_id: params[:local_group_id]) if params[:local_group_id]
    @events = @events.and(activity_id: params[:activity_id]) if params[:activity_id]
    if params[:carousel_id]
      @events = if params[:carousel_id] == 'featured'
                  @events.and(featured: true)
                else
                  @events.and(:id.in => EventTagship.and(:event_tag_id.in => Carousel.find(carousel_id).event_tags.pluck(:id)).pluck(:event_id))
                end
    end
    @events = @events.online if params[:online]
    @events = @events.in_person if params[:in_person]
    @events = @events.and(monthly_donors_only: true) if params[:members_events]
    @events = @events.and(featured: true) if params[:featured]
    if params[:featured_or_course]
      @events = @events.and(:id.in =>
        @organisation.events.and(featured: true).pluck(:id) +
        @organisation.events.course.pluck(:id))
    end
    case content_type
    when :json
      @events = if params[:past]
                  @events.past
                else
                  @events.future_and_current_featured(@from)
                end
      @events.map do |event|
        {
          id: event.id.to_s,
          slug: event.slug,
          name: event.name,
          cohosts: event.cohosts.map { |organisation| { name: organisation.name, slug: organisation.slug } },
          facilitators: event.event_facilitators.map { |account| { name: account.name, username: account.username } },
          activity: event.activity ? { name: event.activity.name, id: event.activity_id.to_s } : nil,
          local_group: event.local_group ? { name: event.local_group.name, id: event.local_group_id.to_s } : nil,
          email: event.email,
          tags: event.event_tags.map(&:name),
          start_time: event.start_time,
          end_time: event.end_time,
          location: event.location,
          time_zone: event.time_zone,
          image: event.image.thumb('1920x1920').url,
          description: event.description
        }
      end.to_json
    when :html
      @events = if params[:past]
                  @events.past
                else
                  @events.future_and_current_featured(@from)
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
          partial :'maps/map', locals: { stem: "/o/#{@organisation.slug}/events", dynamic: true, points: @points, points_count: @points_count, centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom }
        else
          partial :'organisations/events'
        end
      else
        erb :'organisations/events', layout: (params[:minimal] ? 'minimal' : nil)
      end
    when :ics
      @events = @events.current(3.months.ago)
      cal = RiCal.Calendar do |rcal|
        rcal.add_x_property('X-WR-CALNAME', 'Dandelion')
        @events.each do |event|
          next if event.draft?

          rcal.event do |revent|
            if @organisation.ical_full
              revent.summary = event.name
              revent.dtstart = event.start_time
              revent.dtend = event.end_time
            else
              revent.summary = (event.start_time.to_date == event.end_time.to_date ? event.name : "#{event.name} starts")
              revent.dtstart = (event.start_time.to_date == event.end_time.to_date ? event.start_time : event.start_time.to_date)
              revent.dtend = (event.start_time.to_date == event.end_time.to_date ? event.end_time : event.start_time.to_date)
            end
            revent.location = event.location
            revent.description = %(#{ENV['BASE_URI']}/events/#{event.id})
            revent.uid = event.id.to_s
          end
        end
      end
      cal.export
    end
  end

  get '/o/:slug/carousels/:id' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    if params[:id] == 'featured'
      partial :'events/carousel', locals: { title: 'Featured', events: @organisation.featured_events, hide_featured_title: params[:hide_featured_title], skip_margin: true }
    else
      carousel = @organisation.carousels.find(params[:id]) || not_found
      partial :'events/carousel', locals: { title: carousel.name, events: carousel.events }
    end
  end

  get '/o/:slug/orders', provides: %i[html csv] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @from = params[:from] ? Date.parse(params[:from]) : nil
    @to = params[:to] ? Date.parse(params[:to]) : nil
    @orders = @organisation.orders
    @orders = @orders.and(:account_id.in => search_accounts(params[:q]).pluck(:id)) if params[:q]
    @orders = @orders.and(:created_at.gte => @from) if @from
    @orders = @orders.and(:created_at.lt => @to + 1) if @to
    @orders = @orders.and(affiliate_type: 'Organisation', affiliate_id: params[:affiliate_id]) if params[:affiliate_id]
    case content_type
    when :html
      erb :'organisations/orders'
    when :csv
      CSV.generate do |csv|
        csv << %w[name email value currency opt_in_organisation opt_in_facilitator hear_about answers created_at]
        @orders.each do |order|
          csv << [
            order.account ? order.account.name : '',
            if order_email_viewer?(order)
              order.account ? order.account.email : ''
            else
              ''
            end,
            order.value,
            order.currency,
            order.opt_in_organisation,
            order.opt_in_facilitator,
            order.hear_about,
            order.answers,
            order.created_at.to_fs(:db_local)
          ]
        end
      end
    end
  end

  get '/o/:slug/events/stats' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @from = params[:from] ? Date.parse(params[:from]) : Date.today
    @to = params[:to] ? Date.parse(params[:to]) : nil
    @events = @organisation.events_including_cohosted
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order('start_time asc')
    q_ids = []
    q_ids += search_events(params[:q]).pluck(:id) if params[:q]
    event_tag_ids = []
    event_tag_ids = EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id) if params[:event_tag_id]
    event_ids = (!q_ids.empty? && !event_tag_ids.empty? ? (q_ids & event_tag_ids) : (q_ids + event_tag_ids))
    @events = @events.and(:id.in => event_ids) unless event_ids.empty?
    @events = @events.and(local_group_id: params[:local_group_id]) if params[:local_group_id]
    @events = @events.and(activity_id: params[:activity_id]) if params[:activity_id]
    @events = @events.and(coordinator_id: params[:coordinator_id]) if params[:coordinator_id]
    @events = @events.and(coordinator_id: nil) if params[:no_coordinator]
    @events = @events.and(:id.nin => EventFacilitation.pluck(:event_id)) if params[:no_facilitators]
    @events = @events.and(:start_time.gte => @from)
    @events = @events.and(:start_time.lt => @to + 1) if @to
    @events = @events.online if params[:online]
    @events = @events.in_person if params[:in_person]
    erb :'organisations/event_stats'
  end

  post '/o/:slug/organisationships/admin' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find_by(account_id: params[:organisationship][:account_id]) || @organisation.organisationships.create(account_id: params[:organisationship][:account_id])
    @organisationship.update_attribute(:admin, true) if @organisationship.persisted?
    redirect back
  end

  post '/o/:slug/organisationships/unadmin' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find_by(account_id: params[:account_id]) || not_found
    @organisationship.update_attribute(:admin, nil)
    redirect back
  end

  get '/o/:slug/destroy' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation.destroy
    redirect '/o/new'
  end

  get '/organisationships/:id/disconnect' do
    sign_in_required!
    @organisationship = current_account.organisationships.find(params[:id]) || not_found
    @organisationship.update_attribute(:stripe_connect_json, nil)
    redirect "/o/#{@organisationship.organisation.slug}"
  end

  get '/o/:slug/stripe_connect' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
    begin
      response = Mechanize.new.post 'https://connect.stripe.com/oauth/token', client_secret: @organisation.stripe_sk, code: params[:code], grant_type: 'authorization_code'
      @organisationship.update_attribute(:stripe_connect_json, response.body)
      Stripe.api_key = @organisation.stripe_sk
      Stripe.api_version = '2020-08-27'
      @organisationship.update_attribute(:stripe_account_json, Stripe::Account.retrieve(@organisationship.stripe_user_id).to_json)
      flash[:notice] = "Connected to #{@organisation.name}!"
    rescue StandardError
      flash[:error] = 'There was an error connecting your account'
    end
    redirect "/o/#{@organisation.slug}"
  end

  get '/o/:slug/organisationship' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    case params[:f]
    when 'not_following'
      organisationship = current_account.organisationships.find_by(organisation: @organisation)
      organisationship.destroy if organisationship && !organisationship.admin? && !organisationship.monthly_donor?
    when 'follow_without_subscribing'
      organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
      organisationship.update_attribute(:unsubscribed, true)
    when 'follow_and_subscribe'
      organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
      organisationship.update_attribute(:unsubscribed, false)
    end
    if request.xhr?
      partial :'organisations/organisationship', locals: { organisation: @organisation, btn_class: params[:btn_class] }
    else
      redirect "/o/#{@organisation.slug}"
    end
  end

  get '/o/:slug/unsubscribe' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
    @organisationship.update_attribute(:unsubscribed, true)
    flash[:notice] = "You were unsubscribed from #{@organisation.name}."
    redirect '/accounts/subscriptions'
  end

  get '/o/:slug/subscribe_discussion' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
    partial :'organisations/subscribe_discussion', locals: { organisationship: @organisationship }
  end

  get '/o/:slug/set_subscribe_discussion' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
    @organisationship.update_attribute(:subscribed_discussion, true)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
  end

  get '/o/:slug/unsubscribe_discussion' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
    @organisationship.update_attribute(:subscribed_discussion, false)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
  end

  get '/o/:slug/tiers' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.new
    erb :'organisation_tiers/organisation_tiers'
  end

  post '/o/:slug/organisation_tiers/new' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.build(params[:organisation_tier])
    if @organisation_tier.save
      redirect "/o/#{@organisation.slug}/tiers"
    else
      flash.now[:error] = 'There was an error saving the tier.'
      erb :'organisation_tiers/organisation_tiers'
    end
  end

  get '/o/:slug/organisation_tiers/:organisation_tier_id/edit' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.find(params[:organisation_tier_id])
    erb :'organisation_tiers/build'
  end

  post '/o/:slug/organisation_tiers/:organisation_tier_id/edit' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.find(params[:organisation_tier_id])
    if @organisation_tier.update_attributes(mass_assigning(params[:organisation_tier], OrganisationTier))
      redirect "/o/#{@organisation.slug}/tiers"
    else
      flash.now[:error] = 'There was an error saving the tier.'
      erb :'organisation_tiers/build'
    end
  end

  get '/o/:slug/organisation_tiers/:organisation_tier_id/destroy' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation_tier = @organisation.organisation_tiers.find(params[:organisation_tier_id])
    @organisation_tier.destroy
    redirect "/o/#{@organisation.slug}/tiers"
  end

  get '/o/:slug/members' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = @organisation.organisationships.find_by(account: current_account)
    organisation_monthly_donors_plus_only!
    erb :'organisations/monthly_donors'
  end

  get '/o/:slug/followers', provides: %i[html csv] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationships = @organisation.organisationships.order('created_at desc')
    @organisationships = @organisationships.and(:account_id.in => Account.and(name: /#{Regexp.escape(params[:name])}/i).pluck(:id)) if params[:name]
    @organisationships = @organisationships.and(:account_id.in => Account.and(email: /#{Regexp.escape(params[:email])}/i).pluck(:id)) if params[:email]
    @organisationships = @organisationships.and(:monthly_donation_method.ne => nil) if params[:monthly_donor]
    @organisationships = @organisationships.and(monthly_donation_method: nil) if params[:not_a_monthly_donor]
    @organisationships = @organisationships.and(:stripe_connect_json.ne => nil) if params[:connected_to_stripe]
    @organisationships = @organisationships.and(:account_id.in => @organisation.subscribed_accounts.pluck(:id)) if params[:subscribed_to_mailer]
    case content_type
    when :html
      erb :'organisations/followers'
    when :csv
      @organisation.send_followers_csv(current_account)
      flash[:notice] = 'You will receive the CSV via email shortly.'
      redirect back
    end
  end

  get '/o/:slug/subscribed_accounts_count' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisation.subscribed_accounts_count.to_s
  end

  get '/o/:slug/monthly_donors_count' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisation.monthly_donors_count.to_s
  end

  get '/o/:slug/monthly_donations_count' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisation.monthly_donations_count.to_s
  end

  post '/o/:slug/followers' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation.import_from_csv(open(params[:csv]).read)
    redirect "/o/#{@organisation.slug}/followers"
  end

  get '/o/:slug/via/:username' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @account = Account.find_by(username: params[:username]) || not_found
    @og_image = @organisation.affiliate_share_image_url
    @fulltitle = "#{@account.name} invites you to become a member of #{@organisation.name}"
    erb :'organisations/referral'
  end

  get '/organisationships/:id/destroy' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only!
    @organisationship.destroy
    redirect back
  end

  get '/organisationships/:id/credit_balance' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only! unless current_account && current_account.id == @organisationship.account_id
    erb :'organisations/credit_balance'
  end

  post '/organisationships/:id/credit/:plus_or_minus' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only!
    @organisationship.creditings.create(account: current_account, amount: (params[:plus_or_minus] == 'plus' ? 1 : -1) * params[:amount].to_i, currency: @organisation.currency)
    redirect back
  end

  post '/organisationships/:id/referrer' do
    sign_in_required!
    @organisationship = current_account.organisationships.find(params[:id]) || not_found
    @organisationship.hide_referrer = nil
    @organisationship.referrer_id = params[:organisationship][:referrer_id]
    @organisationship.save
    redirect back
  end

  get '/organisationships/:id/hide_referrer' do
    sign_in_required!
    @organisationship = current_account.organisationships.find(params[:id]) || not_found
    @organisationship.hide_referrer = true
    @organisationship.save
    redirect back
  end

  get '/o/:slug/stats' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/stats'
  end

  get '/o/:slug/pmails', provides: [:html, :json] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @_organisation = @organisation
    organisation_admins_only!
    @pmails = @organisation.pmails
    @pmails = @pmails.and(subject: /#{Regexp.escape(params[:q])}/i) if params[:q]
    @scope = "organisation_id=#{@organisation.id}"
    case content_type
    when :html
      @pmails = @pmails.order('created_at desc').page(params[:page])
      erb :'pmails/pmails'
    when :json
      {
        results: @pmails.map { |pmail| { id: pmail.id.to_s, text: "#{pmail.subject} (id:#{pmail.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/pmail_tests' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @pmail_tests = @organisation.pmail_tests.order('created_at desc').page(params[:page])
    @scope = "organisation_id=#{@organisation.id}"
    erb :'pmail_tests/pmail_tests'
  end

  get '/o/:slug/show_membership/:f' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = @organisation.organisationships.find_by(account: current_account) || not_found
    @organisationship.update_attribute(:hide_membership, params[:f].to_i == 0)
    redirect back
  end

  get '/o/:slug/show_feedback' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    if request.xhr? || params[:minimal]
      partial :'event_feedbacks/event_feedbacks', locals: { unscoped: true, event_feedbacks: @organisation.unscoped_event_feedbacks }, layout: (params[:minimal] ? 'minimal' : false)
    else
      redirect "/o/#{@organisation.slug}"
    end
  end

  get '/o/:slug/receive_feedback/:f' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find_by(account: current_account) || not_found
    @organisationship.update_attribute(:receive_feedback, params[:f].to_i == 1)
    redirect back
  end

  get '/o/:slug/subscribed/:organisationship_id' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find(params[:organisationship_id]) || not_found
    partial :'organisations/subscribed', locals: { organisationship: @organisationship }
  end

  post '/o/:slug/subscribed/:organisationship_id' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find(params[:organisationship_id]) || not_found
    @organisationship.update_attribute(:unsubscribed, !params[:subscribed])
    200
  end

  get '/o/:slug/subscribed_discussion/:organisationship_id' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find(params[:organisationship_id]) || not_found
    partial :'organisations/subscribed_discussion', locals: { organisationship: @organisationship }
  end

  post '/o/:slug/subscribed_discussion/:organisationship_id' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisationship = @organisation.organisationships.find(params[:organisationship_id]) || not_found
    @organisationship.update_attribute(:subscribed_discussion, params[:subscribed_discussion])
    200
  end

  get '/organisationships/:id/notes' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only!
    partial :'organisations/notes', locals: { organisationship: @organisationship }
  end

  post '/organisationships/:id/notes' do
    @organisationship = Organisationship.find(params[:id]) || not_found
    @organisation = @organisationship.organisation
    organisation_admins_only!
    @organisationship.update_attribute(:notes, params[:notes])
    200
  end

  get '/o/:slug/discount_codes' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @discount_codes = @organisation.discount_codes
    @scope = "organisation_id=#{@organisation.id}"
    erb :'discount_codes/discount_codes'
  end

  get '/o/:slug/carousels' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @carousels = @organisation.carousels.order('o asc')
    erb :'carousels/carousels'
  end
end
