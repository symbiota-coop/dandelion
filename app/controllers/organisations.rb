Dandelion::App.controller do
  get '/organisations', provides: %i[html json] do
    case content_type
    when :html
      @organisations = Organisation.and(:hidden.ne => true).order('created_at desc').paginate(page: params[:organisations_page], per_page: 50)
      erb :'organisations/organisations'
    when :json
      @organisations = Organisation.all.order('created_at desc')
      @organisations = @organisations.and(name: /#{::Regexp.escape(params[:q])}/i) if params[:q]
      @organisations = @organisations.and(id: params[:id]) if params[:id]
      {
        results: @organisations.map { |organisation| { id: organisation.id.to_s, text: "#{organisation.name} (id:#{organisation.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/activities', provides: %i[html json] do
    @organisation = (Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found)
    @activities = @organisation.activities.order('name asc')
    @activities = @activities.and(name: /#{::Regexp.escape(params[:q])}/i) if params[:q]
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
    @local_groups = @local_groups.and(name: /#{::Regexp.escape(params[:q])}/i) if params[:q]
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
      erb :'organisations/news', layout: ('minimal' if params[:minimal])
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
    if @organisation.save
      redirect "/o/#{@organisation.slug}/edit?tab=2"
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
      redirect "/o/#{@organisation.slug}/edit"
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

  get '/o/:slug/services' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @services = @organisation.services_for_search
    if request.xhr?
      partial :'organisations/services'
    else
      erb :'organisations/services'
    end
  end

  get '/o/:slug/services/stats' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @services = @organisation.services
    q_ids = []
    if params[:q]
      q_ids += Service.all.or(
        { name: /#{::Regexp.escape(params[:q])}/i },
        { description: /#{::Regexp.escape(params[:q])}/i }
      ).pluck(:id)
      @services = @services.and(:id.in => q_ids)
    end
    erb :'organisations/service_stats'
  end

  get '/o/:slug/events', provides: %i[html ics] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    if request.xhr?
      @events = @organisation.events_for_search(include_all_local_group_events: (true if params[:local_group_id])).future_and_current_featured
      @events = @events.and(monthly_donors_only: true) if params[:members_events]
      partial :'organisations/events'
    else
      @events = @organisation.events_for_search(include_all_local_group_events: (true if params[:local_group_id]))
      @from = params[:from] ? Date.parse(params[:from]) : Date.today
      @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order('start_time asc')
      q_ids = []
      if params[:q]
        q_ids += Event.all.or(
          { name: /#{::Regexp.escape(params[:q])}/i },
          { description: /#{::Regexp.escape(params[:q])}/i }
        ).pluck(:id)
      end
      event_tag_ids = []
      event_tag_ids = EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id) if params[:event_tag_id]
      event_ids = (!q_ids.empty? && !event_tag_ids.empty? ? (q_ids & event_tag_ids) : (q_ids + event_tag_ids))
      @events = @events.and(:id.in => event_ids) unless event_ids.empty?
      @events = @events.and(local_group_id: params[:local_group_id]) if params[:local_group_id]
      @events = @events.and(activity_id: params[:activity_id]) if params[:activity_id]
      @events = @events.online if params[:online]
      @events = @events.and(monthly_donors_only: true) if params[:members_events]
      @events = @events.and(featured: true) if params[:featured]
      if params[:featured_or_course]
        @events = @events.and(:id.in =>
          @organisation.events.and(featured: true).pluck(:id) +
          @organisation.events.course.pluck(:id))
      end
      case content_type
      when :html
        @events = if params[:past]
                    @events.past
                  else
                    @events.future_and_current_featured(@from)
                  end
        erb :'organisations/events', layout: ('minimal' if params[:minimal])
      when :ics
        @events = @events.current(3.months.ago)
        cal = RiCal.Calendar do |rcal|
          rcal.add_x_property('X-WR-CALNAME', 'Dandelion')
          @events.each do |event|
            next if event.draft?

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
  end

  get '/o/:slug/carousels/:i' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    if params[:i] == 'featured'
      partial :'events/carousel', locals: { title: 'Featured', events: @organisation.featured_events }
    else
      line = @organisation.carousels.split("\n").reject { |line| line.blank? }[params[:i].to_i]
      title, tags = line.split(':')
      title, w = title.split('[')
      w = w ? w.split(']').first.to_i : 8
      tags = tags.split(',').map(&:strip)
      @events = @organisation.events_for_search.future_and_current_featured.and(:draft.ne => true).and(:start_time.lt => w.weeks.from_now).and(:image_uid.ne => nil).and(:id.in => EventTagship.and(:event_tag_id.in => EventTag.and(:name.in => tags).pluck(:id)).pluck(:event_id)).limit(20)
      partial :'events/carousel', locals: { title: title, events: @events }
    end
  end

  get '/o/:slug/orders' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @orders = @organisation.orders
    if params[:q]
      @orders = @orders.and(:account_id.in => Account.all.or(
        { name: /#{::Regexp.escape(params[:q])}/i },
        { email: params[:q].downcase }
      ).pluck(:id))
    end
    @orders = @orders.and(:coinbase_checkout_id.ne => nil) if params[:coinbase]
    @orders = @orders.and(:seeds_secret.ne => nil) if params[:seeds]
    @orders = @orders.and(:xdai_secret.ne => nil) if params[:xdai]
    if request.xhr?
      partial :'events/orders', locals: { orders: @orders, event_name: true, show_emails: true }
    else
      erb :'organisations/orders'
    end
  end

  get '/o/:slug/bookings' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @bookings = @organisation.bookings
    if params[:q]
      @bookings = @bookings.and(:account_id.in => Account.all.or(
        { name: /#{::Regexp.escape(params[:q])}/i },
        { email: params[:q].downcase }
      ).pluck(:id))
    end
    if request.xhr?
      partial :'services/bookings', locals: { bookings: @bookings, service_name: true, show_emails: true }
    else
      erb :'organisations/bookings'
    end
  end

  get '/o/:slug/events/stats' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @from = params[:from] ? Date.parse(params[:from]) : Date.today
    @to = params[:to] ? Date.parse(params[:to]) : nil
    @events = @organisation.events
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order('start_time asc')
    q_ids = []
    if params[:q]
      q_ids += Event.all.or(
        { name: /#{::Regexp.escape(params[:q])}/i },
        { description: /#{::Regexp.escape(params[:q])}/i }
      ).pluck(:id)
    end
    event_tag_ids = []
    event_tag_ids = EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id) if params[:event_tag_id]
    event_ids = (!q_ids.empty? && !event_tag_ids.empty? ? (q_ids & event_tag_ids) : (q_ids + event_tag_ids))
    @events = @events.and(:id.in => event_ids) unless event_ids.empty?
    @events = @events.and(local_group_id: params[:local_group_id]) if params[:local_group_id]
    @events = @events.and(activity_id: params[:activity_id]) if params[:activity_id]
    @events = @events.and(coordinator_id: params[:coordinator_id]) if params[:coordinator_id]
    @events = @events.and(coordinator_id: nil) if params[:no_coordinator]
    @events = @events.and(:start_time.gte => @from)
    @events = @events.and(:start_time.lt => @to + 1) if @to
    @events = @events.online if params[:online]
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
    case content_type
    when :html
      @organisationships = @organisationships.and(:account_id.in => Account.and(name: /#{::Regexp.escape(params[:name])}/i).pluck(:id)) if params[:name]
      @organisationships = @organisationships.and(:account_id.in => Account.and(email: /#{::Regexp.escape(params[:email])}/i).pluck(:id)) if params[:email]
      @organisationships = @organisationships.and(:monthly_donation_method.ne => nil) if params[:monthly_donor]
      @organisationships = @organisationships.and(monthly_donation_method: nil) if params[:not_a_monthly_donor]
      @organisationships = @organisationships.and(:slack_member.ne => nil) if params[:slack_member]
      @organisationships = @organisationships.and(slack_member: nil) if params[:not_a_slack_member]
      @organisationships = @organisationships.and(:stripe_connect_json.ne => nil) if params[:connected_to_stripe]
      @organisationships = @organisationships.and(:account_id.in => @organisation.subscribed_accounts.pluck(:id)) if params[:subscribed_to_mailer]
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
    organisation_admins_only!
    @pmails = @organisation.pmails
    @pmails = @pmails.and(subject: /#{::Regexp.escape(params[:q])}/i) if params[:q]
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
end
