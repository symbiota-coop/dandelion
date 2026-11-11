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
    organisation_id = params.dig(:local_group, :organisation_id)
    @organisation = (Organisation.find(organisation_id) if organisation_id) || not_found
    organisation_admins_only!
    @local_group = @organisation.local_groups.new(mass_assigning(params[:local_group], LocalGroup))
    @local_group.account = current_account
    if @local_group.save
      flash[:notice] = 'The local group was created.'
      redirect @local_group.path
    else
      flash.now[:error] = 'There was an error saving the local group'
      erb :'local_groups/build'
    end
  end

  # Local group URLs named local groups by id before they used slugs: /local_groups/:id/... is now
  # /o/:organisation_slug/lg/:slug/...
  get '/local_groups/:id' do
    redirect_to_slug_url(LocalGroup, '/local_groups', &:path)
  end

  %i[get post].each do |verb|
    send(verb, '/local_groups/:id/*') do
      redirect_to_slug_url(LocalGroup, '/local_groups', &:path)
    end
  end

  get '/o/:organisation_slug/lg/:slug', prerender: true do
    @local_group = local_group_from_params || not_found
    @title = @local_group.name
    erb :'local_groups/local_group'
  end

  get '/o/:organisation_slug/lg/:slug/events/stats' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    subgroup_event_stats_page(@local_group)
  end

  get '/o/:organisation_slug/lg/:slug/edit' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    erb :'local_groups/build'
  end

  post '/o/:organisation_slug/lg/:slug/edit' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    if @local_group.update_attributes(mass_assigning(params[:local_group], LocalGroup))
      flash[:notice] = 'The local group was saved.'
      redirect @local_group.path
    else
      @edit_path = "/o/#{params[:organisation_slug]}/lg/#{params[:slug]}/edit" # Use the original slugs for the form action, not the (possibly invalid) in-memory ones
      flash.now[:error] = 'There was an error saving the local group'
      erb :'local_groups/build'
    end
  end

  get '/o/:organisation_slug/lg/:slug/stats' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    erb :'local_groups/stats'
  end

  post '/o/:organisation_slug/lg/:slug/add_follower' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!

    @account = account_from_email_param!

    if @local_group.local_groupships.find_by(account: @account)
      flash[:warning] = 'That person is already following the local group'
    else
      @account.associate_with_local_group!(@local_group)
    end

    redirect back
  end

  post '/o/:organisation_slug/lg/:slug/receive_feedback/:f' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.set(receive_feedback: params[:f].to_i == 1)
    redirect back
  end

  # The admins box on a local group's page is a pagelet, which reloads from this after each add or remove
  get '/o/:organisation_slug/lg/:slug/local_groupships/admins' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    partial :'local_groups/admins_box'
  end

  post '/o/:organisation_slug/lg/:slug/local_groupships/admin' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account_id: params[:local_groupship][:account_id]) || @local_group.local_groupships.create(account_id: params[:local_groupship][:account_id])
    @local_groupship.set(admin: true)
    redirect back
  end

  post '/o/:organisation_slug/lg/:slug/local_groupships/unadmin' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account_id: params[:account_id]) || not_found
    @local_groupship.set(admin: false)
    redirect back
  end

  post '/o/:organisation_slug/lg/:slug/destroy' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    @local_group.destroy
    redirect "/o/#{@local_group.organisation.slug}/local_groups"
  end

  get '/o/:organisation_slug/lg/:slug/unsubscribe' do
    sign_in_required!
    @local_group = local_group_from_params || not_found
    erb :'local_groups/unsubscribe'
  end

  post '/o/:organisation_slug/lg/:slug/unsubscribe' do
    sign_in_required!
    @local_group = local_group_from_params || not_found
    @local_groupship = current_account.local_groupships.find_by(local_group: @local_group) || current_account.local_groupships.create(local_group: @local_group)
    @local_groupship.set(unsubscribed: true)
    flash[:notice] = "You were unsubscribed from #{@local_group.name}."
    redirect '/accounts/subscriptions'
  end

  get '/o/:organisation_slug/lg/:slug/local_groupship' do
    sign_in_required!
    @local_group = local_group_from_params || not_found
    request.xhr? ? (partial :'activities_and_local_groups/resourceship', locals: { resource: @local_group, resourceship_name: 'local_groupship', resource_path: @local_group.path, membership_toggle: params[:membership_toggle], btn_class: params[:btn_class] }) : redirect(@local_group.path)
  end

  post '/o/:organisation_slug/lg/:slug/local_groupship' do
    sign_in_required!
    @local_group = local_group_from_params || not_found
    set_own_subgroupship(@local_group, :local_groupships, params[:f])
    request.xhr? ? 200 : redirect(@local_group.path)
  end

  post '/o/:organisation_slug/lg/:slug/hide_membership' do
    sign_in_required!
    @local_group = local_group_from_params || not_found
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.set(hide_membership: true)
    redirect back
  end

  post '/o/:organisation_slug/lg/:slug/show_membership' do
    sign_in_required!
    @local_group = local_group_from_params || not_found
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.set(hide_membership: false)
    redirect back
  end

  get '/o/:organisation_slug/lg/:slug/followers', provides: %i[html csv] do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    case content_type
    when :html
      @local_groupships = subgroup_followers(@local_group, :local_groupships).paginate(page: params[:page], per_page: 25)
      erb :'local_groups/followers'
    when :csv
      send_subgroup_followers_csv(@local_group, :local_groupships)
    end
  end

  post '/o/:organisation_slug/lg/:slug/followers' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    import_subgroup_followers(@local_group, :local_groupships)
  end

  post '/local_groupships/:id/destroy' do
    @local_groupship = LocalGroupship.find(params[:id]) || not_found
    @local_group = @local_groupship.local_group
    local_group_admins_only!
    @local_groupship.destroy
    redirect back
  end

  get '/o/:organisation_slug/lg/:slug/pmails' do
    @local_group = local_group_from_params || not_found
    @_organisation = @local_group.organisation
    local_group_admins_only!
    @pmails = @local_group.pmails_including_events.order('created_at desc').paginate(page: params[:page])
    @scope = "local_group_id=#{@local_group.id}"
    erb :'pmails/pmails'
  end

  get '/o/:organisation_slug/lg/:slug/subscribed/:local_groupship_id' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find(params[:local_groupship_id]) || not_found
    partial :'local_groups/subscribed', locals: { local_groupship: @local_groupship }
  end

  post '/o/:organisation_slug/lg/:slug/subscribed/:local_groupship_id' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find(params[:local_groupship_id]) || not_found
    @local_groupship.set(unsubscribed: !params[:subscribed])
    200
  end

  get '/o/:organisation_slug/lg/:slug/discount_codes' do
    @local_group = local_group_from_params || not_found
    local_group_admins_only!
    @discount_codes = @local_group.discount_codes
    @scope = "local_group_id=#{@local_group.id}"
    erb :'discount_codes/discount_codes'
  end
end
