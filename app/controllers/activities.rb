Dandelion::App.controller do
  get '/activities/new' do
    sign_in_required!
    @activity = Activity.new
    @activity.organisation_id = params[:organisation_id]
    erb :'activities/build'
  end

  post '/activities/new' do
    sign_in_required!
    @activity = Activity.new(mass_assigning(params[:activity], Activity))
    @activity.account = current_account
    if @activity.save
      flash[:notice] = 'The activity was created.'
      redirect "/activities/#{@activity.id}"
    else
      flash.now[:error] = 'There was an error saving the activity'
      erb :'activities/build'
    end
  end

  get '/activities/:id' do
    @activity = Activity.find(params[:id]) || not_found
    @title = @activity.name
    if @activity.hidden? && !activity_admin?
      flash[:warning] = 'That activity is hidden.'
      redirect "/o/#{@activity.organisation.slug}"
    end
    @activityship = @activity.activityships.find_by(account: current_account) if current_account
    erb :'activities/activity'
  end

  get '/activities/:id/events/stats' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @start_or_end = (params[:start_or_end] == 'end' ? 'end' : 'start')
    @events = @activity.events
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order("#{@start_or_end}_time asc")
    q_ids = []
    q_ids += search_events(params[:q]).pluck(:id) if params[:q]
    event_tag_ids = []
    event_tag_ids = EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id) if params[:event_tag_id]
    event_ids = (!q_ids.empty? && !event_tag_ids.empty? ? (q_ids & event_tag_ids) : (q_ids + event_tag_ids))
    @events = @events.and(:id.in => event_ids) unless event_ids.empty?
    @events = @events.and(:"#{@start_or_end}_time".gte => @from)
    @events = @events.and(:"#{@start_or_end}_time".lt => @to + 1) if @to
    @events = @events.and(coordinator_id: params[:coordinator_id]) if params[:coordinator_id]
    @events = @events.and(coordinator_id: nil) if params[:no_coordinator]
    @events = @events.and(:id.nin => EventFacilitation.pluck(:event_id)) if params[:no_facilitators]
    @events = @events.online if params[:online]
    @events = @events.in_person if params[:in_person]
    erb :'events/event_stats'
  end

  get '/activities/:id/edit' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    erb :'activities/build'
  end

  post '/activities/:id/edit' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    if @activity.update_attributes(mass_assigning(params[:activity], Activity))
      flash[:notice] = 'The activity was saved.'
      redirect "/activities/#{@activity.id}"
    else
      flash.now[:error] = 'There was an error saving the activity.'
      erb :'activities/build'
    end
  end

  get '/activities/:id/stats' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    erb :'activities/stats'
  end

  post '/activities/:id/add_follower' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!

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

    if @activity.activityships.find_by(account: @account)
      flash[:warning] = 'That person is already following the activity'
    else
      @activity.organisation.organisationships.create account: @account
      @activity.activityships.create! account: @account
    end

    redirect back
  end

  get '/activities/:id/receive_feedback/:f' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.update_attribute(:receive_feedback, params[:f].to_i == 1)
    redirect back
  end

  post '/activities/:id/activityships/admin' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account_id: params[:activityship][:account_id]) || @activity.activityships.create(account_id: params[:activityship][:account_id])
    @activityship.update_attribute(:admin, true)
    redirect back
  end

  post '/activities/:id/activityships/unadmin' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account_id: params[:account_id]) || not_found
    @activityship.update_attribute(:admin, nil)
    redirect back
  end

  get '/activities/:id/destroy' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activity.destroy
    redirect '/activities/new'
  end

  get '/activities/:id/unsubscribe' do
    sign_in_required!
    @activity = Activity.find(params[:id]) || not_found
    @activityship = current_account.activityships.find_by(activity: @activity) || current_account.activityships.create(activity: @activity)
    @activityship.update_attribute(:unsubscribed, true)
    flash[:notice] = "You were unsubscribed from #{@activity.name}."
    redirect '/accounts/subscriptions'
  end

  get '/activities/:id/activityship' do
    sign_in_required!
    @activity = Activity.find(params[:id]) || not_found
    if (activityship = current_account.activityships.find_by(activity: @activity)) || @activity.privacy == 'open'
      case params[:f]
      when 'not_following'
        activityship = current_account.activityships.find_by(activity: @activity)
        activityship.destroy if activityship && !activityship.admin?
      when 'follow_without_subscribing'
        activityship = current_account.activityships.find_by(activity: @activity) || current_account.activityships.create(activity: @activity)
        activityship.update_attribute(:unsubscribed, true)
      when 'follow_and_subscribe'
        activityship = current_account.activityships.find_by(activity: @activity) || current_account.activityships.create(activity: @activity)
        activityship.update_attribute(:unsubscribed, false)
      end
    end
    request.xhr? ? (partial :'activities/activityship', locals: { activity: @activity, btn_class: params[:btn_class] }) : redirect("/activities/#{@activity.id}")
  end

  get '/activities/:id/hide_membership' do
    sign_in_required!
    @activity = Activity.find(params[:id]) || not_found
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.update_attribute(:hide_membership, true)
    redirect back
  end

  get '/activities/:id/show_membership' do
    sign_in_required!
    @activity = Activity.find(params[:id]) || not_found
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.update_attribute(:hide_membership, false)
    redirect back
  end

  get '/activities/:id/followers', provides: %i[html csv] do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityships = @activity.activityships.order('created_at desc')
    @activityships = @activityships.and(:account_id.in => Account.and(name: /#{Regexp.escape(params[:name])}/i).pluck(:id)) if params[:name]
    @activityships = @activityships.and(:account_id.in => Account.and(email: /#{Regexp.escape(params[:email])}/i).pluck(:id)) if params[:email]
    @activityships = @activityships.and(:account_id.in => @activity.subscribed_accounts.pluck(:id)) if params[:subscribed_to_mailer]
    case content_type
    when :html
      @activityships = @activityships.paginate(page: params[:page], per_page: 25)
      erb :'activities/followers'
    when :csv
      @activity.send_followers_csv(current_account)
      flash[:notice] = 'You will receive the CSV via email shortly.'
      redirect back
    end
  end

  post '/activities/:id/followers' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activity.import_from_csv(File.read(params[:csv]), :activityships)
    flash[:notice] = 'The followers will be added shortly. Refresh the page to check progress.'
    redirect "/activities/#{@activity.id}/followers"
  end

  get '/activityships/:id/destroy' do
    @activityship = Activityship.find(params[:id]) || not_found
    @activity = @activityship.activity
    activity_admins_only!
    @activityship.destroy
    redirect back
  end

  get '/activities/:id/show_feedback' do
    @activity = Activity.find(params[:id]) || not_found
    @organisation = @activity.organisation
    if request.xhr? || params[:minimal]
      partial :'event_feedbacks/event_feedbacks', locals: { event_feedbacks: @activity.event_feedbacks }, layout: (params[:minimal] ? 'minimal' : false)
    else
      redirect "/activities/#{@activity.id}"
    end
  end

  get '/activities/:id/pmails' do
    @activity = Activity.find(params[:id]) || not_found
    @_organisation = @activity.organisation
    activity_admins_only!
    @pmails = @activity.pmails_including_events.order('created_at desc').page(params[:page])
    @scope = "activity_id=#{@activity.id}"
    erb :'pmails/pmails'
  end

  get '/activities/:id/subscribed/:activityship_id' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find(params[:activityship_id]) || not_found
    partial :'activities/subscribed', locals: { activityship: @activityship }
  end

  post '/activities/:id/subscribed/:activityship_id' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find(params[:activityship_id]) || not_found
    @activityship.update_attribute(:unsubscribed, !params[:subscribed])
    200
  end

  get '/activities/:id/discount_codes' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @discount_codes = @activity.discount_codes
    @scope = "activity_id=#{@activity.id}"
    erb :'discount_codes/discount_codes'
  end
end
