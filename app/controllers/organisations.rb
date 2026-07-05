Dandelion::App.controller do
  get '/organisations', provides: %i[html json] do
    @organisations = Organisation.and(hidden: false)
    @organisations = params[:order] == 'created_at' ? @organisations.order('created_at desc') : @organisations.order('followers_count desc')
    @organisations = @organisations.and(:id.in => current_account.organisations_following.pluck(:id)) if current_account && params[:following]
    @organisations = @organisations.and(:id.in => Organisation.search(params[:q], @organisations).pluck(:id)) if params[:q]

    case content_type
    when :html
      @organisations = @organisations.paginate(page: params[:organisations_page], per_page: 16)
      erb :'organisations/organisations'
    when :json
      map_json(@organisations)
    end
  end

  get '/organisations/autocomplete', provides: :json do
    @organisations = Organisation.all.order('created_at desc')
    @organisations = @organisations.and(:id.in => Organisation.search(params[:q], @organisations).pluck(:id)) if params[:q]
    @organisations = @organisations.and(id: params[:id]) if params[:id]
    {
      results: @organisations.only(:name, :slug).map { |organisation| { id: organisation.id.to_s, text: "#{organisation.name} (#{organisation.slug})" } }
    }.to_json
  end

  get '/o/:slug/activities', provides: %i[html json] do
    @organisation = Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found
    @activities = @organisation.activities.order('name asc')
    @activities = @activities.and(:id.in => Activity.search(params[:q], @activities).pluck(:id)) if params[:q]
    @activities = @activities.and(id: params[:id]) if params[:id]
    case content_type
    when :html
      unlocked = @activities.and(locked: false)
      @inactive_activities = unlocked.without_upcoming_events
      @activities = unlocked.with_upcoming_events
      if request.xhr?
        partial :'organisations/activities'
      else
        erb :'organisations/activities'
      end
    when :json
      {
        results: @activities.only(:name).map { |activity| { id: activity.id.to_s, text: "#{activity.name} (id:#{activity.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/local_groups', provides: %i[html json] do
    @organisation = Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found
    @local_groups = @organisation.local_groups.order('name asc')
    @local_groups = @local_groups.and(:id.in => LocalGroup.search(params[:q], @local_groups).pluck(:id)) if params[:q]
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
        results: @local_groups.only(:name).map { |local_group| { id: local_group.id.to_s, text: "#{local_group.name} (id:#{local_group.id})" } }
      }.to_json
    end
  end

  get '/o/:slug/news' do
    @organisation = Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found
    @pmails = @organisation.news
    if request.xhr?
      partial :'organisations/news'
    else
      erb :'organisations/news', layout: (params[:minimal] ? 'minimal' : nil)
    end
  end

  get '/o/:slug/news/latest' do
    @organisation = Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found
    @pmails = @organisation.news
    redirect "/pmails/#{@pmails.first.id}"
  end

  get '/o/:slug/subscribe' do
    @organisation = Organisation.find_by(slug: params[:slug]) || Organisation.find(params[:slug]) || not_found
    @skip_minimal_head = true
    partial :'accounts/minimal_subscribe', layout: 'minimal'
  end

  get '/invite/:id' do
    account = Account.find(params[:id]) || not_found
    session[:organisation_referrer_id] = account.id.to_s
    redirect '/o/new'
  end

  get '/o/new' do
    sign_in_required!
    @organisation = Organisation.new(mass_assigning(params[:organisation], Organisation))
    @organisation.account = current_account
    erb :'organisations/build'
  end

  post '/o/new' do
    sign_in_required!
    @organisation = Organisation.new(mass_assigning(params[:organisation], Organisation))
    @organisation.account = current_account
    if (referrer_id = session[:organisation_referrer_id]) &&
       @organisation.referrer_id.blank? &&
       !(current_account && referrer_id == current_account.id.to_s)
      @organisation.referrer_id = referrer_id if Account.find(referrer_id)
    end
    @organisation.show_details_table_in_ticket_emails = true
    @organisation.show_sign_in_link_in_ticket_emails = true
    @organisation.show_ticketholder_link_in_ticket_emails = true
    if @organisation.save
      session.delete(:organisation_referrer_id)
      redirect "/o/#{@organisation.slug}/edit?created=1&tab=payments"
    else
      flash.now[:error] = 'There was an error saving the organisation.'
      erb :'organisations/build'
    end
  end

  get '/o/:slug', prerender: true do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @title = @organisation.name
    erb :'organisations/organisation'
  end

  get '/o/:slug/carousels/:id' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    if params[:id] == 'featured'
      partial :'events/carousel', locals: { title: 'Featured', events: @organisation.featured_events, hide_featured_title: params[:hide_featured_title], skip_margin: true }
    else
      carousel = @organisation.carousels.find(params[:id]) || not_found
      partial :'events/carousel', locals: { title: carousel.name, events: carousel.events(minimal: params[:minimal]) }
    end
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
      organisationship.set_unsubscribed!(true)
    when 'follow_and_subscribe'
      organisationship = current_account.organisationships.find_by(organisation: @organisation) || current_account.organisationships.create(organisation: @organisation)
      organisationship.set_unsubscribed!(false)
    end
    if request.xhr?
      partial :'organisations/organisationship', locals: { organisation: @organisation, membership_toggle: params[:membership_toggle], create_event: params[:create_event], btn_class: params[:btn_class] }
    else
      redirect "/o/#{@organisation.slug}"
    end
  end

  get '/o/:slug/unsubscribe' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @account = current_account || Account.from_organisation_unsubscribe_token(@organisation, params[:token]) || sign_in_required!
    erb :'organisations/unsubscribe'
  end

  post '/o/:slug/unsubscribe' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @account = current_account || Account.from_organisation_unsubscribe_token(@organisation, params[:token]) || sign_in_required!
    @organisationship = @account.organisationships.find_by(organisation: @organisation) || @account.organisationships.create(organisation: @organisation)
    @organisationship.set_unsubscribed!(true)
    if params[:token]
      @unsubscribed = true
      erb :'organisations/unsubscribe'
    else
      flash[:notice] = "You were unsubscribed from #{@organisation.name}."
      redirect '/accounts/subscriptions'
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

  get '/o/:slug/show_membership/:f' do
    sign_in_required!
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @organisationship = @organisation.organisationships.find_by(account: current_account) || not_found
    hide = params[:f].to_i == 0
    @organisationship.set(hide_membership: hide)
    if hide
      current_account.set(organisation_ids_public_cache: (current_account.organisation_ids_public_cache || []) - [@organisation.id])
    else
      current_account.set(organisation_ids_public_cache: ((current_account.organisation_ids_public_cache || []) + [@organisation.id]).uniq)
    end
    redirect back
  end

  get '/o/:slug/show_feedback' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    if request.xhr? || params[:minimal]
      partial :'event_feedbacks/event_feedbacks', locals: { event_feedbacks: @organisation.unscoped_event_feedbacks }, layout: (params[:minimal] ? 'minimal' : false)
    else
      redirect "/o/#{@organisation.slug}"
    end
  end
end
