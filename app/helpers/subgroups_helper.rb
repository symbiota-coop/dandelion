# The routes activities and local groups share (see Subgroup). Each route stays written out in its own controller, with
# its lookup and permission check, and calls these for the rest
Dandelion::App.helpers do
  # Its events stats page, filtered by the form above it
  def subgroup_event_stats_page(subgroup)
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @start_or_end = (params[:start_or_end] == 'end' ? 'end' : 'start')
    @events = subgroup.events.without_heavy_fields
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order("#{@start_or_end}_time asc")
    @events = apply_event_stats_date_filter(@events, from: @from, to: @to, start_or_end: @start_or_end, include_evergreen: params[:evergreen])
    @events = @events.and(coordinator_id: params[:coordinator_id]) if params[:coordinator_id]
    @events = @events.and(coordinator_id: nil) if params[:no_coordinator]
    @events = @events.and(:id.nin => EventFacilitation.pluck(:event_id)) if params[:no_facilitators]
    # Ticking both online and in person shows all events, unlike apply_online_in_person_filter
    unless params[:online] && params[:in_person]
      @events = @events.online if params[:online]
      @events = @events.in_person if params[:in_person]
    end
    @events = filter_events_by_search_and_tags(@events)
    event_stats_page(subgroup.organisation)
  end

  # Its followers, newest first, filtered by the search above the list
  def subgroup_followers(subgroup)
    followers = subgroup.subgroupships.includes(:account).order('created_at desc')
    followers = followers.and(:account_id.in => Account.search(params[:q], child_scope: followers).pluck(:id)) if params[:q]
    followers = followers.and(unsubscribed: false, :account_id.nin => subgroup.organisation.mailer_unsubscribed_member_ids) if params[:subscribed_to_mailer]
    followers
  end

  def send_subgroup_followers_csv(subgroup)
    subgroup.send_followers_csv(current_account, subgroup.subgroupships_name)
    flash[:notice] = 'You will receive the CSV via email shortly.'
    redirect back
  end

  def import_subgroup_followers(subgroup)
    halt 400 unless params[:csv].is_a?(Tempfile)
    csv = ImportFromCsv.read(params[:csv])
    if (error = ImportFromCsv.error(csv))
      flash[:error] = error
    else
      subgroup.import_from_csv(csv, subgroup.subgroupships_name)
      flash[:notice] = 'The followers will be added shortly. Refresh the page to check progress.'
    end
    redirect "#{subgroup.path}/followers"
  end

  # The follow button: following is not_following, follow_without_subscribing or follow_and_subscribe. Admins can't
  # unfollow
  def set_own_subgroupship(subgroup, following)
    subgroupship = subgroup.subgroupships.find_by(account: current_account)
    case following
    when 'not_following'
      subgroupship.destroy if subgroupship && !subgroupship.admin?
    when 'follow_without_subscribing', 'follow_and_subscribe'
      subgroupship ||= subgroup.subgroupships.create(account: current_account)
      subgroupship.set(unsubscribed: following == 'follow_without_subscribing')
    end
  end

  # Its settings form, new or edited: saves it and goes to it, or shows the form again with the errors
  def save_subgroup(subgroup, template)
    created = subgroup.new_record?
    subgroup.assign_attributes(mass_assigning(params[subgroup.class.model_name.param_key], subgroup.class))
    subgroup.account = current_account if created
    if subgroup.save
      flash[:notice] = "The #{subgroup.kind_name} was #{created ? 'created' : 'saved'}."
      redirect subgroup.path
    else
      @edit_path = request.path unless created # The form posts back to the URL it came from, not to the (possibly invalid) new slugs
      flash.now[:error] = "There was an error saving the #{subgroup.kind_name}"
      erb template
    end
  end

  # Admins add a follower by email: associate adds them, as each kind of subgroup does it its own way
  def add_subgroup_follower(subgroup, &associate)
    account = account_from_email_param!
    if subgroup.subgroupships.find_by(account: account)
      flash[:warning] = "That person is already following the #{subgroup.kind_name}"
    else
      associate.call(account)
    end
    redirect back
  end

  # The unsubscribe link in its emails: subgroupship is the signed-in account's, or nil if they don't follow it
  def unsubscribe_from_subgroup(subgroup, subgroupship)
    subgroupship&.set(unsubscribed: true)
    flash[:notice] = "You were unsubscribed from #{subgroup.name}."
    redirect '/accounts/subscriptions'
  end

  # The follow button, loaded into the page
  def subgroupship_button(subgroup)
    return redirect(subgroup.path) unless request.xhr?

    partial :'activities_and_local_groups/resourceship', locals: {
      resource: subgroup, resourceship_name: subgroup.subgroupship_name, resource_path: subgroup.path,
      membership_toggle: params[:membership_toggle], btn_class: params[:btn_class]
    }
  end

  def subgroup_followers_page(subgroup, template)
    case content_type
    when :html
      @subgroupships = subgroup_followers(subgroup).paginate(page: params[:page], per_page: 25)
      erb template
    when :csv
      send_subgroup_followers_csv(subgroup)
    end
  end

  # Its mailer, and the discount codes page: both list what's scoped to it, as activity_id=... or local_group_id=...
  def subgroup_pmails_page(subgroup)
    @_organisation = subgroup.organisation
    @pmails = subgroup.pmails_including_events.order('created_at desc').paginate(page: params[:page])
    @scope = "#{subgroup.class.model_name.singular}_id=#{subgroup.id}"
    erb :'pmails/pmails'
  end

  def subgroup_discount_codes_page(subgroup)
    @discount_codes = subgroup.discount_codes
    @scope = "#{subgroup.class.model_name.singular}_id=#{subgroup.id}"
    erb :'discount_codes/discount_codes'
  end
end
