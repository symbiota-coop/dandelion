# The routes activities and local groups share. Each route stays written out in its own controller, with its lookup and
# permission check, and calls these for the rest. subgroupships is the subgroup's memberships, :activityships or
# :local_groupships
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
  def subgroup_followers(subgroup, subgroupships)
    followers = subgroup.public_send(subgroupships).includes(:account).order('created_at desc')
    followers = followers.and(:account_id.in => Account.search(params[:q], child_scope: followers).pluck(:id)) if params[:q]
    followers = followers.and(unsubscribed: false, :account_id.nin => subgroup.organisation.mailer_unsubscribed_member_ids) if params[:subscribed_to_mailer]
    followers
  end

  def send_subgroup_followers_csv(subgroup, subgroupships)
    subgroup.send_followers_csv(current_account, subgroupships)
    flash[:notice] = 'You will receive the CSV via email shortly.'
    redirect back
  end

  def import_subgroup_followers(subgroup, subgroupships)
    halt 400 unless params[:csv].is_a?(Tempfile)
    csv = ImportFromCsv.read(params[:csv])
    if (error = ImportFromCsv.error(csv))
      flash[:error] = error
    else
      subgroup.import_from_csv(csv, subgroupships)
      flash[:notice] = 'The followers will be added shortly. Refresh the page to check progress.'
    end
    redirect "#{subgroup.path}/followers"
  end

  # The follow button: following is not_following, follow_without_subscribing or follow_and_subscribe. Admins can't
  # unfollow
  def set_own_subgroupship(subgroup, subgroupships, following)
    subgroupship = subgroup.public_send(subgroupships).find_by(account: current_account)
    case following
    when 'not_following'
      subgroupship.destroy if subgroupship && !subgroupship.admin?
    when 'follow_without_subscribing', 'follow_and_subscribe'
      subgroupship ||= subgroup.public_send(subgroupships).create(account: current_account)
      subgroupship.set(unsubscribed: following == 'follow_without_subscribing')
    end
  end
end
