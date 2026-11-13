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
    @local_group = @organisation.local_groups.new
    save_subgroup(@local_group, :'local_groups/build')
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
    @local_group = local_group_from_params
    @title = @local_group.name
    erb :'local_groups/local_group'
  end

  get '/o/:organisation_slug/lg/:slug/events/stats' do
    @local_group = local_group_from_params
    local_group_admins_only!
    subgroup_event_stats_page(@local_group)
  end

  get '/o/:organisation_slug/lg/:slug/edit' do
    @local_group = local_group_from_params
    local_group_admins_only!
    erb :'local_groups/build'
  end

  post '/o/:organisation_slug/lg/:slug/edit' do
    @local_group = local_group_from_params
    local_group_admins_only!
    save_subgroup(@local_group, :'local_groups/build')
  end

  get '/o/:organisation_slug/lg/:slug/stats' do
    @local_group = local_group_from_params
    local_group_admins_only!
    erb :'local_groups/stats'
  end

  post '/o/:organisation_slug/lg/:slug/add_follower' do
    @local_group = local_group_from_params
    local_group_admins_only!
    add_subgroup_follower(@local_group) { |account| account.associate_with_local_group!(@local_group) }
  end

  post '/o/:organisation_slug/lg/:slug/receive_feedback/:f' do
    @local_group = local_group_from_params
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.set(receive_feedback: params[:f].to_i == 1)
    redirect back
  end

  # The admins box on a local group's page is a pagelet, which reloads from this after each add or remove
  get '/o/:organisation_slug/lg/:slug/local_groupships/admins' do
    @local_group = local_group_from_params
    local_group_admins_only!
    partial :'activities_and_local_groups/admins_box', locals: { resource: @local_group }
  end

  post '/o/:organisation_slug/lg/:slug/local_groupships/admin' do
    @local_group = local_group_from_params
    local_group_admins_only!
    @local_group.local_groupships.find_or_create_by(account_id: params[:local_groupship][:account_id]).set(admin: true)
    redirect back
  end

  post '/o/:organisation_slug/lg/:slug/local_groupships/unadmin' do
    @local_group = local_group_from_params
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account_id: params[:account_id]) || not_found
    @local_groupship.set(admin: false)
    redirect back
  end

  post '/o/:organisation_slug/lg/:slug/destroy' do
    @local_group = local_group_from_params
    local_group_admins_only!
    @local_group.destroy
    redirect "/o/#{@local_group.organisation.slug}/local_groups"
  end

  get '/o/:organisation_slug/lg/:slug/unsubscribe' do
    sign_in_required!
    @local_group = local_group_from_params
    erb :'local_groups/unsubscribe'
  end

  # Someone who doesn't follow the local group is made an unsubscribed follower
  post '/o/:organisation_slug/lg/:slug/unsubscribe' do
    sign_in_required!
    @local_group = local_group_from_params
    unsubscribe_from_subgroup(@local_group, @local_group.local_groupships.find_or_create_by(account: current_account))
  end

  get '/o/:organisation_slug/lg/:slug/local_groupship' do
    sign_in_required!
    @local_group = local_group_from_params
    subgroupship_button(@local_group)
  end

  post '/o/:organisation_slug/lg/:slug/local_groupship' do
    sign_in_required!
    @local_group = local_group_from_params
    set_own_subgroupship(@local_group, params[:f])
    request.xhr? ? 200 : redirect(@local_group.path)
  end

  post '/o/:organisation_slug/lg/:slug/hide_membership' do
    sign_in_required!
    @local_group = local_group_from_params
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.set(hide_membership: true)
    redirect back
  end

  post '/o/:organisation_slug/lg/:slug/show_membership' do
    sign_in_required!
    @local_group = local_group_from_params
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.set(hide_membership: false)
    redirect back
  end

  get '/o/:organisation_slug/lg/:slug/followers', provides: %i[html csv] do
    @local_group = local_group_from_params
    local_group_admins_only!
    subgroup_followers_page(@local_group, :'local_groups/followers')
  end

  post '/o/:organisation_slug/lg/:slug/followers' do
    @local_group = local_group_from_params
    local_group_admins_only!
    import_subgroup_followers(@local_group)
  end

  post '/local_groupships/:id/destroy' do
    @local_groupship = LocalGroupship.find(params[:id]) || not_found
    @local_group = @local_groupship.local_group
    local_group_admins_only!
    @local_groupship.destroy
    redirect back
  end

  get '/o/:organisation_slug/lg/:slug/pmails' do
    @local_group = local_group_from_params
    local_group_admins_only!
    subgroup_pmails_page(@local_group)
  end

  get '/o/:organisation_slug/lg/:slug/subscribed/:local_groupship_id' do
    @local_group = local_group_from_params
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find(params[:local_groupship_id]) || not_found
    partial :'activities_and_local_groups/subscribed', locals: { resource: @local_group, resourceship: @local_groupship }
  end

  post '/o/:organisation_slug/lg/:slug/subscribed/:local_groupship_id' do
    @local_group = local_group_from_params
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find(params[:local_groupship_id]) || not_found
    @local_groupship.set(unsubscribed: !params[:subscribed])
    200
  end

  get '/o/:organisation_slug/lg/:slug/discount_codes' do
    @local_group = local_group_from_params
    local_group_admins_only!
    subgroup_discount_codes_page(@local_group)
  end
end
