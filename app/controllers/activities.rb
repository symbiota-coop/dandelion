Dandelion::App.controller do
  get '/activities/new' do
    halt 400 unless params[:organisation_id]
    @organisation = Organisation.find(params[:organisation_id]) || not_found
    organisation_admins_only!
    @activity = Activity.new
    @activity.organisation = @organisation
    erb :'activities/build'
  end

  post '/activities/new' do
    @activity = Activity.new(mass_assigning(params[:activity], Activity))
    @activity.account = current_account
    @organisation = @activity.organisation
    organisation_admins_only!
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
    redirect "/o/#{@activity.organisation.slug}/a/#{@activity.slug}"
  end

  get '/o/:organisation_slug/a/:slug', prerender: true do
    organisation = Organisation.find_by(slug: params[:organisation_slug]) || not_found
    @activity = organisation.activities.find_by(slug: params[:slug]) || not_found
    @title = @activity.name
    kick!(redirect_url: "/o/#{@activity.organisation.slug}") if @activity.locked? && !activity_admin?
    @activityship = @activity.activityships.find_by(account: current_account) if current_account
    erb :'activities/activity'
  end

  get '/activities/:id/feedback_summary' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    if !admin? && @activity.feedback_summary_last_refreshed_at && @activity.feedback_summary_last_refreshed_at > 24.hours.ago
      flash[:error] = 'Feedback summary can only be refreshed once per day'
    else
      @activity.feedback_summary!
    end
    redirect request.referrer ? "#{request.referrer}#feedback" : back
  end

  get '/activities/:id/feedback_summary/delete' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activity.set(feedback_summary: nil)
    @activity.set(feedback_summary_last_refreshed_at: Time.now)
    flash[:notice] = 'Feedback summary removed.'
    redirect request.referrer ? "#{request.referrer}#feedback" : back
  end

  get '/activities/:id/events/stats' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @start_or_end = (params[:start_or_end] == 'end' ? 'end' : 'start')
    @events = @activity.events
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
      @account.associate_with_activity!(@activity)
    end

    redirect back
  end

  get '/activities/:id/receive_feedback/:f' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.set(receive_feedback: params[:f].to_i == 1)
    redirect back
  end

  post '/activities/:id/activityships/admin' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account_id: params[:activityship][:account_id]) || @activity.activityships.create(account_id: params[:activityship][:account_id])
    @activityship.set(admin: true)
    redirect back
  end

  post '/activities/:id/activityships/unadmin' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account_id: params[:account_id]) || not_found
    @activityship.set(admin: false)
    redirect back
  end

  get '/activities/:id/destroy' do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activity.destroy
    redirect "/o/#{@activity.organisation.slug}/activities"
  end

  get '/activities/:id/unsubscribe' do
    sign_in_required!
    @activity = Activity.find(params[:id]) || not_found
    erb :'activities/unsubscribe'
  end

  post '/activities/:id/unsubscribe' do
    sign_in_required!
    @activity = Activity.find(params[:id]) || not_found
    @activityship = current_account.activityships.find_by(activity: @activity) || current_account.activityships.create(activity: @activity)
    @activityship.set(unsubscribed: true)
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
        activityship.set(unsubscribed: true)
      when 'follow_and_subscribe'
        activityship = current_account.activityships.find_by(activity: @activity) || current_account.activityships.create(activity: @activity)
        activityship.set(unsubscribed: false)
      end
    end
    request.xhr? ? (partial :'activities_and_local_groups/resourceship', locals: { resource: @activity, resourceship_name: 'activityship', resource_path: "/activities/#{@activity.id}", membership_toggle: params[:membership_toggle], btn_class: params[:btn_class] }) : redirect("/activities/#{@activity.id}")
  end

  get '/activities/:id/hide_membership' do
    sign_in_required!
    @activity = Activity.find(params[:id]) || not_found
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.set(hide_membership: true)
    redirect back
  end

  get '/activities/:id/show_membership' do
    sign_in_required!
    @activity = Activity.find(params[:id]) || not_found
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.set(hide_membership: false)
    redirect back
  end

  get '/activities/:id/followers', provides: %i[html csv] do
    @activity = Activity.find(params[:id]) || not_found
    activity_admins_only!
    @activityships = @activity.activityships.includes(:account).order('created_at desc')
    @activityships = @activityships.and(:account_id.in => Account.search(params[:q], child_scope: @activityships).pluck(:id)) if params[:q]
    if params[:subscribed_to_mailer]
      # Filter to activity-subscribed, then exclude globally unsubscribed and org-unsubscribed
      @activityships = @activityships.and(unsubscribed: false)
      excluded_ids = Account.and(organisation_ids_cache: @activity.organisation_id).and(
        :$or => [{ unsubscribed: true }, { unsubscribed_organisation_ids_cache: @activity.organisation_id }]
      ).pluck(:id)
      @activityships = @activityships.and(:account_id.nin => excluded_ids) if excluded_ids.any?
    end
    case content_type
    when :html
      @activityships = @activityships.paginate(page: params[:page], per_page: 25)
      erb :'activities/followers'
    when :csv
      @activity.send_followers_csv(current_account, :activityships)
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
      partial :'event_feedbacks/event_feedbacks', locals: { event_feedbacks: @activity.event_feedbacks.includes(:account, event: :organisation) }, layout: (params[:minimal] ? 'minimal' : false)
    else
      redirect "/activities/#{@activity.id}"
    end
  end

  get '/activities/:id/pmails' do
    @activity = Activity.find(params[:id]) || not_found
    @_organisation = @activity.organisation
    activity_admins_only!
    @pmails = @activity.pmails_including_events.order('created_at desc').paginate(page: params[:page])
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
    @activityship.set(unsubscribed: !params[:subscribed])
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
