Dandelion::App.helpers do
  def duplicate_event_prerequisites!
    organisation = @event.organisation
    if Padrino.env == :production && !organisation.stripe_client_id && organisation.stripe_sk && !organisation.stripe_connect_json
      @organisation = organisation
      halt erb(:'events/stripe_connect')
    elsif organisation.contribution_reminder && !params[:contribution_skipped]
      redirect "/o/#{organisation.slug}/contribute?return_to=#{CGI.escape("/events/#{@event.id}/duplicate")}"
    end
  end

  def filter_events_by_search_and_tags(events)
    q_ids = []
    q_ids += Event.search(params[:q], events).pluck(:id) if params[:q]
    event_tag_ids = []
    if params[:event_type]
      event_tag_ids = if (event_tag = EventTag.find_by(name: params[:event_type]))
                        event_tag.event_ids
                      else
                        []
                      end
    elsif params[:event_tag_id]
      event_tag_ids = EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id)
    end
    event_ids = if q_ids.empty?
                  event_tag_ids
                elsif event_tag_ids.empty?
                  q_ids
                else
                  q_ids & event_tag_ids
                end
    events = events.and(:id.in => event_ids) if params[:q] || params[:event_tag_id] || params[:event_type]
    events
  end

  def apply_online_in_person_filter(events)
    if params[:online]
      events = events.online
      params[:in_person] = false
    end
    if params[:in_person]
      events = events.in_person
      params[:online] = false
    end
    events
  end

  def apply_event_stats_date_filter(events, from:, to:, start_or_end:, include_evergreen:)
    return events.and(evergreen: true) if include_evergreen

    date_field = :"#{start_or_end}_time"
    events = events.and(date_field.gte => from)
    events = events.and(date_field.lt => to + 1) if to
    events
  end

  def apply_events_order(events)
    case params[:order]
    when 'created_at'
      events.order('created_at desc')
    when 'featured'
      events.order('featured desc, start_time asc')
    else
      events.order('start_time asc')
    end
  end

  # For lists that aren't paginated (the grid, and the list in an embed): the first 100 events, and whether there are
  # more, since rendering hundreds of event cards takes many seconds. events may be EventIds (random or trending order)
  def capped_events(events, limit: 100)
    events = events.is_a?(EventIds) ? events.paginate(page: 1, per_page: limit + 1).to_a : events.limit(limit + 1).to_a
    [events.first(limit), events.length > limit]
  end

  # The paginated list of an organisation's events, with the current filters
  def all_events_url(organisation)
    query = request.GET.except('display', 'minimal', 'page', 'per_page', '_t')
    "/o/#{organisation.slug}/events#{"?#{query.to_query}" unless query.empty?}"
  end

  def event_block_cache_key(event)
    "/events/#{event.id}?organisation_id=#{@organisation.try(:id)}#{event_viewer_timezone_query(event)}&current_account=#{current_account ? 1 : 0}"
  end

  def event_block_carousel_cache_key(event)
    "/events/#{event.id}/block_carousel?organisation_id=#{@organisation.try(:id)}#{event_viewer_timezone_query(event)}"
  end

  def apply_random_or_trending_order(events, from)
    case params[:order]
    when 'random'
      event_ids = events.pluck(:id)
      return EventIds.new if event_ids.empty?

      sampled_ids = events.collection.aggregate([
                                                  { '$match' => { '_id' => { '$in' => event_ids } } },
                                                  { '$sample' => { size: event_ids.length } },
                                                  { '$project' => { '_id' => 1 } }
                                                ]).map { |hash| hash['_id'] }
      EventIds.new(sampled_ids)
    when 'trending'
      EventIds.new(events.trending_ids(from))
    else
      events
    end
  end

  def apply_geo_filter(events)
    return events unless params[:near]

    if params[:near] == 'online'
      events.online
    elsif set_bounding_box
      events.and(coordinates: { '$geoWithin' => { '$box' => @bounding_box } })
    else
      events
    end
  end

  def calendar_json(events)
    user_time_zone = current_account ? current_account.time_zone : session[:time_zone]
    events.reject(&:evergreen?).map do |event|
      {
        id: event.id.to_s,
        name: event.name,
        start_time: event.start_time.iso8601,
        end_time: event.end_time.iso8601,
        slug: event.slug,
        location: event.location,
        when_details: event.when_details(user_time_zone)
      }
    end.to_json
  end

  def build_events_ical(events, calendar_name, ical_full: false)
    cal = Icalendar::Calendar.new
    cal.append_custom_property('X-WR-CALNAME', calendar_name)
    events.each do |event|
      next if event.evergreen?

      cal.event do |e|
        if ical_full
          e.summary = event.name
          e.dtstart = event.start_time.utc.strftime('%Y%m%dT%H%M%SZ')
          e.dtend = event.end_time.utc.strftime('%Y%m%dT%H%M%SZ')
        else
          same_day = event.start_time.to_date == event.end_time.to_date
          e.summary = same_day ? event.name : "#{event.name} starts"
          e.dtstart = same_day ? event.start_time.utc.strftime('%Y%m%dT%H%M%SZ') : Icalendar::Values::Date.new(event.start_time.to_date)
          e.dtend = same_day ? event.end_time.utc.strftime('%Y%m%dT%H%M%SZ') : nil
        end
        e.location = event.location
        e.description = "#{ENV['BASE_URI']}/e/#{event.slug}"
        e.uid = event.id.to_s
      end
    end
    cal.to_ical
  end

  # Loads events for the stats table or CSV (Event.preload_stats) and yields them, with the urls of the images their
  # rows show (avatars and activity images) found in one query
  def with_stats_events(events)
    events = Event.preload_stats(events)
    accounts = events.flat_map { |event| [event.coordinator, event.organiser, event.revenue_sharer] }.compact.uniq
    images = accounts.filter_map { |account| account.image&.thumb('400x400#') } +
             events.filter_map(&:activity).uniq.filter_map { |activity| activity.image&.thumb('500x500#') }
    DragonflyJob.with_prefetched(images) { yield events }
  end

  # The stats table's rows (events/event_stats_row)
  def event_stats_rows(events, organisation)
    with_stats_events(events) do |stats_events|
      stats_events.map { |event| partial(:'events/event_stats_row', locals: { event: event, organisation: organisation, event_revenue_admin: event_revenue_admin?(event) }) }
    end
  end

  # The CSV's cells are the text of the stats table's cells (event_stats_row/), or their data-csv attribute
  def build_events_stats_csv(events, organisation)
    CSV.generate do |csv|
      headers = ['name']
      headers_basic = %w[date coordinator organiser facilitators tags activity local_group facebook_event views tickets_sold checked_in ticket_revenue donations]
      headers += headers_basic

      if organisation.stripe_client_id
        headers_stripe_client_id = %w[ticket_revenue_to_revenue_sharer ticket_revenue_to_organisation revenue_reported_by_dandelion revenue_reported_by_stripe stripe_fees]
        headers += headers_stripe_client_id
        headers += %w[profit profit_less_donations_before_allocations]
        Event.profit_share_roles.each { |role| headers << "allocated_to_#{role}" }
        headers += %w[profit_less_donations_after_allocations profit_including_donations_after_allocations]
        Event.profit_share_roles.each { |role| headers << "remaining_to_#{role}" }
        headers << 'remaining_to_be_paid'
      end
      headers << 'feedback'
      csv << headers

      with_stats_events(events) do |stats_events|
        stats_events.each do |event|
          cell = ->(name, **locals) { partial(:"event_stats_row/#{name}", locals: { event: event, organisation: organisation, **locals }) }
          row = [event.name]
          row += headers_basic.map { |h| cell.call(h) }

          if organisation.stripe_client_id
            row += headers_stripe_client_id.map { |h| cell.call(h) }
            if event_revenue_admin?(event)
              row += [cell.call(:profit), cell.call(:profit_less_donations_before_allocations)]
              Event.profit_share_roles.each { |role| row << cell.call(:allocated_to_role, role: role) }
              row += [cell.call(:profit_less_donations_after_allocations), cell.call(:profit_including_donations_after_allocations)]
              Event.profit_share_roles.each { |role| row << m(event.send("remaining_to_#{role}").abs, event.currency) }
              row << cell.call(:remaining_to_be_paid)
            else
              row += Array.new(13, '')
            end
          end

          row << cell.call(:feedback)
          row.map! { |c| extract_csv_cell_text(c) }
          csv << row
        end
      end
    end
  end

  def extract_csv_cell_text(cell)
    html = Nokogiri::HTML(cell)
    return cell unless (td = html.at('td'))
    return td['data-csv'] if td['data-csv']

    html.search('script').remove
    td.children.text.split("\n").reject(&:blank?).map(&:strip).join(', ')
  end
end
