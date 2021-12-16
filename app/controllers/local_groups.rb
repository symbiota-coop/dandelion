Dandelion::App.controller do
  get '/local_groups/new' do
    sign_in_required!
    @local_group = LocalGroup.new
    @local_group.organisation_id = params[:organisation_id]
    erb :'local_groups/build'
  end

  post '/local_groups/new' do
    sign_in_required!
    @local_group = LocalGroup.new(mass_assigning(params[:local_group], LocalGroup))
    @local_group.account = current_account
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
    @title = @local_group.name
    erb :'local_groups/local_group'
  end

  get '/local_groups/:id/events/stats' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @from = params[:from] ? Date.parse(params[:from]) : Date.today
    @to = params[:to] ? Date.parse(params[:to]) : nil
    @events = @local_group.events
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
    @events = @events.and(coordinator_id: params[:coordinator_id]) if params[:coordinator_id]
    @events = @events.and(coordinator_id: nil) if params[:no_coordinator]
    @events = @events.and(:start_time.gte => @from)
    @events = @events.and(:start_time.lt => @to + 1) if @to
    @events = @events.online if params[:online]
    erb :'local_groups/event_stats'
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

  post '/local_groups/:id/local_groupships/admin' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account_id: params[:local_groupship][:account_id]) || @local_group.local_groupships.create(account_id: params[:local_groupship][:account_id])
    @local_groupship.update_attribute(:admin, true)
    redirect back
  end

  post '/local_groups/:id/local_groupships/unadmin' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find_by(account_id: params[:account_id]) || not_found
    @local_groupship.update_attribute(:admin, nil)
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
    @local_groupship = current_account.local_groupships.find_by(local_group: @local_group) || current_account.local_groupships.create(local_group: @local_group)
    @local_groupship.update_attribute(:unsubscribed, true)
    flash[:notice] = "You were unsubscribed from #{@local_group.name}."
    redirect '/accounts/subscriptions'
  end

  get '/local_groups/:id/subscribe_discussion' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    @local_groupship = current_account.local_groupships.find_by(local_group: @local_group) || current_account.local_groupships.create(local_group: @local_group)
    partial :'local_groups/subscribe_discussion', locals: { local_groupship: @local_groupship }
  end

  get '/local_groups/:id/set_subscribe_discussion' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    @local_groupship = current_account.local_groupships.find_by(local_group: @local_group) || current_account.local_groupships.create(local_group: @local_group)
    @local_groupship.update_attribute(:subscribed_discussion, true)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
  end

  get '/local_groups/:id/unsubscribe_discussion' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    @local_groupship = current_account.local_groupships.find_by(local_group: @local_group) || current_account.local_groupships.create(local_group: @local_group)
    @local_groupship.update_attribute(:subscribed_discussion, false)
    request.xhr? ? 200 : redirect('/accounts/subscriptions')
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
      local_groupship.update_attribute(:unsubscribed, true)
    when 'follow_and_subscribe'
      local_groupship = current_account.local_groupships.find_by(local_group: @local_group) || current_account.local_groupships.create(local_group: @local_group)
      local_groupship.update_attribute(:unsubscribed, false)
    end
    request.xhr? ? (partial :'local_groups/local_groupship', locals: { local_group: @local_group, btn_class: params[:btn_class] }) : redirect("/local_groups/#{@local_group.id}")
  end

  get '/local_groups/:id/hide_membership' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.update_attribute(:hide_membership, true)
    redirect back
  end

  get '/local_groups/:id/show_membership' do
    sign_in_required!
    @local_group = LocalGroup.find(params[:id]) || not_found
    @local_groupship = @local_group.local_groupships.find_by(account: current_account) || not_found
    @local_groupship.update_attribute(:hide_membership, false)
    redirect back
  end

  get '/local_groups/:id/followers', provides: %i[html csv] do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupships = @local_group.local_groupships.order('created_at desc')
    case content_type
    when :html
      @local_groupships = @local_groupships.and(:account_id.in => Account.and(name: /#{::Regexp.escape(params[:name])}/i).pluck(:id)) if params[:name]
      @local_groupships = @local_groupships.and(:account_id.in => Account.and(email: /#{::Regexp.escape(params[:email])}/i).pluck(:id)) if params[:email]
      @local_groupships = @local_groupships.and(:account_id.in => @local_group.subscribed_accounts.pluck(:id)) if params[:subscribed_to_mailer]
      @local_groupships = @local_groupships.paginate(page: params[:page], per_page: 25)
      erb :'local_groups/followers'
    when :csv
      @local_group.send_followers_csv(current_account)
      flash[:notice] = 'You will receive the CSV via email shortly.'
      redirect back
    end
  end

  post '/local_groups/:id/followers' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_group.import_from_csv(open(params[:csv]).read)
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
    local_group_admins_only!
    @pmails = @local_group.pmails_including_events.order('created_at desc').page(params[:page])
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
    @local_groupship.update_attribute(:unsubscribed, !params[:subscribed])
    200
  end

  get '/local_groups/:id/subscribed_discussion/:local_groupship_id' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find(params[:local_groupship_id]) || not_found
    partial :'local_groups/subscribed_discussion', locals: { local_groupship: @local_groupship }
  end

  post '/local_groups/:id/subscribed_discussion/:local_groupship_id' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @local_groupship = @local_group.local_groupships.find(params[:local_groupship_id]) || not_found
    @local_groupship.update_attribute(:subscribed_discussion, params[:subscribed_discussion])
    200
  end

  get '/local_groups/:id/discount_codes' do
    @local_group = LocalGroup.find(params[:id]) || not_found
    local_group_admins_only!
    @discount_codes = @local_group.discount_codes
    @scope = "activity_id=#{@local_group.id}"
    erb :'discount_codes/discount_codes'
  end
end
