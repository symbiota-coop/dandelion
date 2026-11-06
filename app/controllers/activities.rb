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
    @activity = @organisation.activities.new(mass_assigning(params[:activity], Activity))
    @activity.account = current_account
    if @activity.save
      flash[:notice] = 'The activity was created.'
      redirect @activity.path
    else
      flash.now[:error] = 'There was an error saving the activity'
      erb :'activities/build'
    end
  end

  # Activity URLs named activities by id before they used slugs: /activities/:id/... is now
  # /o/:organisation_slug/a/:slug/...
  get '/activities/:id' do
    activity = Activity.find(params[:id]) || not_found # rubocop:disable Dandelion/SlugLookup -- redirects the old id URL
    redirect_to_slug_url "/activities/#{params[:id]}", activity.path
  end

  %i[get post].each do |verb|
    send(verb, '/activities/:id/*') do
      activity = Activity.find(params[:id]) || not_found # rubocop:disable Dandelion/SlugLookup -- redirects the old id URL
      redirect_to_slug_url "/activities/#{params[:id]}", activity.path
    end
  end

  get '/o/:organisation_slug/a/:slug', prerender: true do
    @activity = activity_from_params || not_found
    @title = @activity.name
    kick!(redirect_url: "/o/#{@activity.organisation.slug}") if @activity.locked? && !activity_admin?
    @activityship = @activity.activityships.find_by(account: current_account) if current_account
    erb :'activities/activity'
  end

  post '/o/:organisation_slug/a/:slug/feedback_summary' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    if !admin? && @activity.feedback_summary_last_refreshed_at && @activity.feedback_summary_last_refreshed_at > 24.hours.ago
      flash[:error] = 'Feedback summary can only be refreshed once per day'
    else
      @activity.request_feedback_summary!
    end
    request.xhr? ? 200 : redirect(back('#feedback'))
  end

  get '/o/:organisation_slug/a/:slug/feedback_summary' do
    @activity = activity_from_params || not_found
    @organisation = @activity.organisation
    partial :'event_feedbacks/feedback_summary', locals: { contents_only: true }
  end

  post '/o/:organisation_slug/a/:slug/feedback_summary/delete' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    @activity.set(feedback_summary: nil)
    @activity.set(feedback_summary_last_refreshed_at: Time.now)
    flash[:notice] = 'Feedback summary removed.'
    redirect back('#feedback')
  end

  get '/o/:organisation_slug/a/:slug/events/stats' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @start_or_end = (params[:start_or_end] == 'end' ? 'end' : 'start')
    @events = @activity.events.without_heavy_fields
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order("#{@start_or_end}_time asc")
    @events = apply_event_stats_date_filter(@events, from: @from, to: @to, start_or_end: @start_or_end, include_evergreen: params[:evergreen])
    @events = @events.and(coordinator_id: params[:coordinator_id]) if params[:coordinator_id]
    @events = @events.and(coordinator_id: nil) if params[:no_coordinator]
    @events = @events.and(:id.nin => EventFacilitation.pluck(:event_id)) if params[:no_facilitators]
    unless params[:online] && params[:in_person]
      @events = @events.online if params[:online]
      @events = @events.in_person if params[:in_person]
    end
    @events = filter_events_by_search_and_tags(@events)
    event_stats_page(@activity.organisation)
  end

  get '/o/:organisation_slug/a/:slug/edit' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    erb :'activities/build'
  end

  post '/o/:organisation_slug/a/:slug/edit' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    if @activity.update_attributes(mass_assigning(params[:activity], Activity))
      flash[:notice] = 'The activity was saved.'
      redirect @activity.path
    else
      @edit_path = "/o/#{params[:organisation_slug]}/a/#{params[:slug]}/edit" # Use the original slugs for the form action, not the (possibly invalid) in-memory ones
      flash.now[:error] = 'There was an error saving the activity.'
      erb :'activities/build'
    end
  end

  get '/o/:organisation_slug/a/:slug/stats' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    erb :'activities/stats'
  end

  post '/o/:organisation_slug/a/:slug/add_follower' do
    @activity = activity_from_params || not_found
    activity_admins_only!

    unless params[:email]
      flash[:error] = 'Please provide an email address'
      redirect back
    end

    unless (@account = Account.find_by(email: params[:email].downcase.strip))
      @account = Account.new(name: params[:email].split('@').first, email: params[:email], password: Account.generate_password)
      unless @account.save
        flash[:error] = '<strong>Oops.</strong> Some errors prevented the account from being saved.'
        redirect back
      end
    end

    if @activity.activityships.find_by(account: @account)
      flash[:warning] = 'That person is already following the activity'
    else
      @account.associate_with_activity!(@activity, force: true)
    end

    redirect back
  end

  post '/o/:organisation_slug/a/:slug/receive_feedback/:f' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.set(receive_feedback: params[:f].to_i == 1)
    redirect back
  end

  # The admins box on an activity's page is a pagelet, which reloads from this after each add or remove
  get '/o/:organisation_slug/a/:slug/activityships/admins' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    partial :'activities/admins_box'
  end

  post '/o/:organisation_slug/a/:slug/activityships/admin' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account_id: params[:activityship][:account_id]) || @activity.activityships.create(account_id: params[:activityship][:account_id])
    @activityship.set(admin: true)
    redirect back
  end

  post '/o/:organisation_slug/a/:slug/activityships/unadmin' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find_by(account_id: params[:account_id]) || not_found
    @activityship.set(admin: false)
    redirect back
  end

  post '/o/:organisation_slug/a/:slug/destroy' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    @activity.destroy
    redirect "/o/#{@activity.organisation.slug}/activities"
  end

  get '/o/:organisation_slug/a/:slug/unsubscribe' do
    sign_in_required!
    @activity = activity_from_params || not_found
    erb :'activities/unsubscribe'
  end

  post '/o/:organisation_slug/a/:slug/unsubscribe' do
    sign_in_required!
    @activity = activity_from_params || not_found
    if (@activityship = current_account.activityships.find_by(activity: @activity))
      @activityship.set(unsubscribed: true)
    end
    flash[:notice] = "You were unsubscribed from #{@activity.name}."
    redirect '/accounts/subscriptions'
  end

  get '/o/:organisation_slug/a/:slug/activityship' do
    sign_in_required!
    @activity = activity_from_params || not_found
    request.xhr? ? (partial :'activities_and_local_groups/resourceship', locals: { resource: @activity, resourceship_name: 'activityship', resource_path: @activity.path, membership_toggle: params[:membership_toggle], btn_class: params[:btn_class] }) : redirect(@activity.path)
  end

  post '/o/:organisation_slug/a/:slug/activityship' do
    sign_in_required!
    @activity = activity_from_params || not_found
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
    request.xhr? ? 200 : redirect(@activity.path)
  end

  post '/o/:organisation_slug/a/:slug/hide_membership' do
    sign_in_required!
    @activity = activity_from_params || not_found
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.set(hide_membership: true)
    redirect back
  end

  post '/o/:organisation_slug/a/:slug/show_membership' do
    sign_in_required!
    @activity = activity_from_params || not_found
    @activityship = @activity.activityships.find_by(account: current_account) || not_found
    @activityship.set(hide_membership: false)
    redirect back
  end

  get '/o/:organisation_slug/a/:slug/followers', provides: %i[html csv] do
    @activity = activity_from_params || not_found
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

  post '/o/:organisation_slug/a/:slug/followers' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    halt 400 unless params[:csv].is_a?(Tempfile)
    csv = ImportFromCsv.read(params[:csv])
    if (error = ImportFromCsv.error(csv))
      flash[:error] = error
    else
      @activity.import_from_csv(csv, :activityships)
      flash[:notice] = 'The followers will be added shortly. Refresh the page to check progress.'
    end
    redirect "#{@activity.path}/followers"
  end

  post '/activityships/:id/destroy' do
    @activityship = Activityship.find(params[:id]) || not_found
    @activity = @activityship.activity
    activity_admins_only!
    @activityship.destroy
    redirect back
  end

  get '/o/:organisation_slug/a/:slug/show_feedback' do
    @activity = activity_from_params || not_found
    @organisation = @activity.organisation
    if request.xhr? || params[:minimal]
      partial :'event_feedbacks/event_feedbacks', locals: { event_feedbacks: @activity.public_event_feedbacks.includes(:account, event: :organisation) }, layout: (params[:minimal] ? 'minimal' : false)
    else
      redirect @activity.path
    end
  end

  get '/o/:organisation_slug/a/:slug/pmails' do
    @activity = activity_from_params || not_found
    @_organisation = @activity.organisation
    activity_admins_only!
    @pmails = @activity.pmails_including_events.order('created_at desc').paginate(page: params[:page])
    @scope = "activity_id=#{@activity.id}"
    erb :'pmails/pmails'
  end

  get '/o/:organisation_slug/a/:slug/subscribed/:activityship_id' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find(params[:activityship_id]) || not_found
    partial :'activities/subscribed', locals: { activityship: @activityship }
  end

  post '/o/:organisation_slug/a/:slug/subscribed/:activityship_id' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    @activityship = @activity.activityships.find(params[:activityship_id]) || not_found
    @activityship.set(unsubscribed: !params[:subscribed])
    200
  end

  get '/o/:organisation_slug/a/:slug/discount_codes' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    @discount_codes = @activity.discount_codes
    @scope = "activity_id=#{@activity.id}"
    erb :'discount_codes/discount_codes'
  end

  get '/o/:organisation_slug/a/:slug/application_questions' do
    @activity = activity_from_params || not_found
    activity_admins_only!
    %w[hide_image hide_location hide_date_of_birth hide_gender].each do |field|
      @activity[field] = %w[1 true on].include?(params[field].to_s) if params.key?(field)
    end
    partial :'activity_applications/application_form_preview', locals: { activity: @activity, questions: params[:questions] }
  end
end
