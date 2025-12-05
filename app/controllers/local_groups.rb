Dandelion::App.controller do
  get '/local_groups/new' do
    halt 400 unless params[:organisation_id]
    @organisation = Organisation.find(params[:organisation_id]) || not_found
    organisation_admins_only!
    @local_group = LocalGroup.new
    @local_group.organisation = @organisation
    erb :'local_groups/build'
  end

  post '/local_groups/new' do
    @local_group = LocalGroup.new(mass_assigning(params[:local_group], LocalGroup))
    @local_group.account = current_account
    @organisation = @local_group.organisation
    organisation_admins_only!
    if @local_group.save
      flash[:notice] = 'The local group was created.'
      redirect "/local_groups/#{@local_group.id}"
    else
      flash.now[:error] = 'There was an error saving the local group'
      erb :'local_groups/build'
    end
  end

  get '/local_groups/:id' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    redirect "/o/#{@local_group.organisation.slug}/lg/#{@local_group.slug}"
  end

  get '/o/:organisation_slug/lg/:slug' do
    organisation = Organisation.find_by(slug: params[:organisation_slug]) || not_found
    @local_group = organisation.local_groups.find_by(slug: params[:slug]) || not_found
    @title = @local_group.name
    erb :'local_groups/local_group'
  end

  get '/local_groups/:id/events/stats' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @start_or_end = (params[:start_or_end] == 'end' ? 'end' : 'start')
    @events = @local_group.events
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order("#{@start_or_end}_time asc")
    @events = @events.and(:"#{@start_or_end}_time".gte => @from)
    @events = @events.and(:"#{@start_or_end}_time".lt => @to + 1) if @to
    @events = @events.and(coordinator_id: params[:coordinator_id]) if params[:coordinator_id]
    @events = @events.and(coordinator_id: nil) if params[:no_coordinator]
    @events = @events.and(:id.nin => EventFacilitation.pluck(:event_id)) if params[:no_facilitators]
    unless params[:online] && params[:in_person]
      @events = @events.online if params[:online]
      @events = @events.in_person if params[:in_person]
    end
    @events = filter_events_by_search_and_tags(@events)
    erb :'events/event_stats'
  end

  get '/local_groups/:id/edit' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    erb :'local_groups/build'
  end

  post '/local_groups/:id/edit' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    if @local_group.update_attributes(mass_assigning(params[:local_group], LocalGroup))
      flash[:notice] = 'The local group was saved.'
      redirect "/local_groups/#{@local_group.id}"
    else
      flash.now[:error] = 'There was an error saving the local group'
      erb :'local_groups/build'
    end
  end

  get '/local_groups/:id/stats' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    erb :'local_groups/stats'
  end

  post '/local_groups/:id/add_follower' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!

    unless params[:email]
      flash[:error] = 'Please provide an email address'
      redirect back
    end

    unless (@account = Account.find_by(email: params[:email].downcase))
      @account = Account.new(name: params[:email].split('@').first, email: params[:email], password: Account.generate_password)
      unless @account.save
        flash[:error] = '<strong>Oops.</strong> Some errors prevented the account from being saved.'
        redirect back
      end
    end

    if @local_group.local_groupships.find_by(account: @account)
      flash[:warning] = 'That person is already following the local group'
    else
      @local_group.organisation.organisationships.create account: @account
      @local_group.local_groupships.create! account: @account
    end

    redirect back
  end

  get '/local_groups/:id/receive_feedback/:f' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.set(receive_feedback: params[:f].to_i == 1)
    redirect back
  end

  post '/local_groups/:id/local_groupships/admin' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account_id: params[:local_groupship][:account_id]) || @local_group.local_groupships.create(account_id: params[:local_groupship][:account_id])
    @local_groupship.set(admin: true)
    redirect back
  end

  post '/local_groups/:id/local_groupships/unadmin' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account_id: params[:account_id]) || not_found
    @local_groupship.set(admin: false)
    redirect back
  end

  get '/local_groups/:id/destroy' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_group.destroy
    redirect '/local_groups/new'
  end

  get '/local_groups/:id/unsubscribe' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    erb :'local_groups/unsubscribe'
  end

  post '/local_groups/:id/unsubscribe' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    @local_groupship = current_account.local_groupships.find_by(local_group: @local_group) || current_account.local_groupships.create(local_group: @local_group)
    @local_groupship.set(unsubscribed: true)
    flash[:notice] = "You were unsubscribed from #{@local_group.name}."
    redirect '/accounts/subscriptions'
  end

  get '/local_groups/:id/local_groupship' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    case params[:f]
    when 'not_following'
      local_groupship = current_account.local_groupships.find_by(local_group: @local_group)
      local_groupship.destroy if local_groupship && !local_groupship.admin?
    when 'follow_without_subscribing'
      local_groupship = current_account.local_groupships.find_by(local_group: @local_group) || current_account.local_groupships.create(local_group: @local_group)
      local_groupship.set(unsubscribed: true)
    when 'follow_and_subscribe'
      local_groupship = current_account.local_groupships.find_by(local_group: @local_group) || current_account.local_groupships.create(local_group: @local_group)
      local_groupship.set(unsubscribed: false)
    end
    request.xhr? ? (partial :'activities_and_local_groups/resourceship', locals: { resource: @local_group, resourceship_name: 'local_groupship', resource_path: "/local_groups/#{@local_group.id}", membership_toggle: params[:membership_toggle], btn_class: params[:btn_class] }) : redirect("/local_groups/#{@local_group.id}")
  end

  get '/local_groups/:id/hide_membership' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.set(hide_membership: true)
    redirect back
  end

  get '/local_groups/:id/show_membership' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.set(hide_membership: false)
    redirect back
  end

  get '/local_groups/:id/followers', provides: %i[html csv] do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupships = @local_group.local_groupships.order('created_at desc')
    @local_groupships = @local_groupships.and(:account_id.in => Account.search(params[:q], child_scope: @local_groupships).pluck(:id)) if params[:q]
    if params[:subscribed_to_mailer]
      # Filter to local_group-subscribed, then exclude globally unsubscribed and org-unsubscribed
      @local_groupships = @local_groupships.and(unsubscribed: false)
      excluded_ids = Account.and(organisation_ids_cache: @local_group.organisation_id).and(
        :$or => [{ unsubscribed: true }, { unsubscribed_organisation_ids_cache: @local_group.organisation_id }]
      ).pluck(:id)
      @local_groupships = @local_groupships.and(:account_id.nin => excluded_ids) if excluded_ids.any?
    end
    case content_type
    when :html
      @local_groupships = @local_groupships.paginate(page: params[:page], per_page: 25)
      erb :'local_groups/followers'
    when :csv
      @local_group.send_followers_csv(current_account, :local_groupships)
      flash[:notice] = 'You will receive the CSV via email shortly.'
      redirect back
    end
  end

  post '/local_groups/:id/followers' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_group.import_from_csv(File.read(params[:csv]), :local_groupships)
    flash[:notice] = 'The followers will be added shortly. Refresh the page to check progress.'
    redirect "/local_groups/#{@local_group.id}/followers"
  end

  get '/local_groupships/:id/destroy' do
    @local_groupship = LocalGroupship.find(params[:id]) || not_found
    @local_group = @local_groupship.local_group
    local_group_admins_only!
    @local_groupship.destroy
    redirect back
  end

  get '/local_groups/:id/pmails' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    @_organisation = @local_group.organisation
    local_group_admins_only!
    @pmails = @local_group.pmails_including_events.order('created_at desc').paginate(page: params[:page])
    @scope = "local_group_id=#{@local_group.id}"
    erb :'pmails/pmails'
  end

  get '/local_groups/:id/subscribed/:local_groupship_id' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find(params[:local_groupship_id]) || not_found
    partial :'local_groups/subscribed', locals: { local_groupship: @local_groupship }
  end

  post '/local_groups/:id/subscribed/:local_groupship_id' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find(params[:local_groupship_id]) || not_found
    @local_groupship.set(unsubscribed: !params[:subscribed])
    200
  end

  get '/local_groups/:id/discount_codes' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @discount_codes = @local_group.discount_codes
    @scope = "local_group_id=#{@local_group.id}"
    erb :'discount_codes/discount_codes'
  end
end
