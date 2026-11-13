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
    organisation_id = params.dig(:activity, :organisation_id)
    @organisation = (Organisation.find(organisation_id) if organisation_id) || not_found
    organisation_admins_only!
    @activity = @organisation.activities.new
    save_subgroup(@activity, :'activities/build')
  end

  # Activity URLs named activities by id before they used slugs: /activities/:id/... is now
  # /o/:organisation_slug/a/:slug/...
  get '/activities/:id' do
    redirect_to_slug_url(Activity, '/activities', &:path)
  end

  %i[get post].each do |verb|
    send(verb, '/activities/:id/*') do
      redirect_to_slug_url(Activity, '/activities', &:path)
    end
  end

  get '/o/:organisation_slug/a/:slug', prerender: true do
    @activity = activity_from_params
    @title = @activity.name
    locked_activity_admins_only!
    @activityship = @activity.activityships.find_by(account: current_account) if current_account
    erb :'activities/activity'
  end

  post '/o/:organisation_slug/a/:slug/feedback_summary' do
    @activity = activity_from_params
    activity_admins_only!
    if !admin? && @activity.feedback_summary_last_refreshed_at && @activity.feedback_summary_last_refreshed_at > 24.hours.ago
      flash[:error] = 'Feedback summary can only be refreshed once per day'
    else
      @activity.request_feedback_summary!
    end
    request.xhr? ? 200 : redirect(back('#feedback'))
  end

  get '/o/:organisation_slug/a/:slug/feedback_summary' do
    @activity = activity_from_params
    locked_activity_admins_only!
    @organisation = @activity.organisation
    partial :'event_feedbacks/feedback_summary', locals: { contents_only: true }
  end

  post '/o/:organisation_slug/a/:slug/feedback_summary/delete' do
    @activity = activity_from_params
    activity_admins_only!
    @activity.set(feedback_summary: nil)
    @activity.set(feedback_summary_last_refreshed_at: Time.now)
    flash[:notice] = 'Feedback summary removed.'
    redirect back('#feedback')
  end

  get '/o/:organisation_slug/a/:slug/events/stats' do
    @activity = activity_from_params
    activity_admins_only!
    subgroup_event_stats_page(@activity)
  end

  get '/o/:organisation_slug/a/:slug/edit' do
    @activity = activity_from_params
    activity_admins_only!
    erb :'activities/build'
  end

  post '/o/:organisation_slug/a/:slug/edit' do
    @activity = activity_from_params
    activity_admins_only!
    save_subgroup(@activity, :'activities/build')
  end

  get '/o/:organisation_slug/a/:slug/stats' do
    @activity = activity_from_params
    activity_admins_only!
    erb :'activities/stats'
  end

  post '/o/:organisation_slug/a/:slug/add_follower' do
    @activity = activity_from_params
    activity_admins_only!
    add_subgroup_follower(@activity) { |account| account.associate_with_activity!(@activity, force: true) }
  end

  post '/o/:organisation_slug/a/:slug/receive_feedback/:f' do
    @activity = activity_from_params
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.set(receive_feedback: params[:f].to_i == 1)
    redirect back
  end

  # The admins box on an activity's page is a pagelet, which reloads from this after each add or remove
  get '/o/:organisation_slug/a/:slug/activityships/admins' do
    @activity = activity_from_params
    activity_admins_only!
    partial :'activities_and_local_groups/admins_box', locals: { resource: @activity }
  end

  post '/o/:organisation_slug/a/:slug/activityships/admin' do
    @activity = activity_from_params
    activity_admins_only!
    @activity.activityships.find_or_create_by(account_id: params[:activityship][:account_id]).set(admin: true)
    redirect back
  end

  post '/o/:organisation_slug/a/:slug/activityships/unadmin' do
    @activity = activity_from_params
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account_id: params[:account_id]) || not_found
    @activityship.set(admin: false)
    redirect back
  end

  post '/o/:organisation_slug/a/:slug/destroy' do
    @activity = activity_from_params
    activity_admins_only!
    @activity.destroy
    redirect "/o/#{@activity.organisation.slug}/activities"
  end

  get '/o/:organisation_slug/a/:slug/unsubscribe' do
    sign_in_required!
    @activity = activity_from_params
    erb :'activities/unsubscribe'
  end

  # Unlike a local group's, this doesn't make someone who doesn't follow the activity a follower
  post '/o/:organisation_slug/a/:slug/unsubscribe' do
    sign_in_required!
    @activity = activity_from_params
    unsubscribe_from_subgroup(@activity, @activity.activityships.find_by(account: current_account))
  end

  get '/o/:organisation_slug/a/:slug/activityship' do
    sign_in_required!
    @activity = activity_from_params
    subgroupship_button(@activity)
  end

  post '/o/:organisation_slug/a/:slug/activityship' do
    sign_in_required!
    @activity = activity_from_params
    # Only open activities can be joined without an admin
    set_own_subgroupship(@activity, params[:f]) if @activity.activityships.find_by(account: current_account) || @activity.privacy == 'open'
    request.xhr? ? 200 : redirect(@activity.path)
  end

  post '/o/:organisation_slug/a/:slug/hide_membership' do
    sign_in_required!
    @activity = activity_from_params
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.set(hide_membership: true)
    redirect back
  end

  post '/o/:organisation_slug/a/:slug/show_membership' do
    sign_in_required!
    @activity = activity_from_params
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.set(hide_membership: false)
    redirect back
  end

  get '/o/:organisation_slug/a/:slug/followers', provides: %i[html csv] do
    @activity = activity_from_params
    activity_admins_only!
    subgroup_followers_page(@activity, :'activities/followers')
  end

  post '/o/:organisation_slug/a/:slug/followers' do
    @activity = activity_from_params
    activity_admins_only!
    import_subgroup_followers(@activity)
  end

  post '/activityships/:id/destroy' do
    @activityship = Activityship.find(params[:id]) || not_found
    @activity = @activityship.activity
    activity_admins_only!
    @activityship.destroy
    redirect back
  end

  get '/o/:organisation_slug/a/:slug/show_feedback' do
    @activity = activity_from_params
    locked_activity_admins_only!
    @organisation = @activity.organisation
    if request.xhr? || params[:minimal]
      partial :'event_feedbacks/event_feedbacks', locals: { event_feedbacks: @activity.public_event_feedbacks.includes(:account, event: :organisation) }, layout: (params[:minimal] ? 'minimal' : false)
    else
      redirect @activity.path
    end
  end

  get '/o/:organisation_slug/a/:slug/pmails' do
    @activity = activity_from_params
    activity_admins_only!
    subgroup_pmails_page(@activity)
  end

  get '/o/:organisation_slug/a/:slug/subscribed/:activityship_id' do
    @activity = activity_from_params
    activity_admins_only!
    @activityship = @activity.activityships.find(params[:activityship_id]) || not_found
    partial :'activities_and_local_groups/subscribed', locals: { resource: @activity, resourceship: @activityship }
  end

  post '/o/:organisation_slug/a/:slug/subscribed/:activityship_id' do
    @activity = activity_from_params
    activity_admins_only!
    @activityship = @activity.activityships.find(params[:activityship_id]) || not_found
    @activityship.set(unsubscribed: !params[:subscribed])
    200
  end

  get '/o/:organisation_slug/a/:slug/discount_codes' do
    @activity = activity_from_params
    activity_admins_only!
    subgroup_discount_codes_page(@activity)
  end

  get '/o/:organisation_slug/a/:slug/application_questions' do
    @activity = activity_from_params
    activity_admins_only!
    %w[hide_image hide_location hide_date_of_birth hide_gender].each do |field|
      @activity[field] = %w[1 true on].include?(params[field].to_s) if params.key?(field)
    end
    partial :'activity_applications/application_form_preview', locals: { activity: @activity, questions: params[:questions] }
  end
end
