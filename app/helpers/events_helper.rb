Dandelion::App.helpers do
  def duplicate_event_prerequisites!
    organisation = @event.organisation
    if organisation.contribution_reminder && !params[:contribution_skipped]
      redirect "/o/#{organisation.slug}/contribute?return_to=#{CGI.escape("/e/#{@event.slug}/duplicate")}"
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
    "/e/#{event.slug}?organisation_id=#{@organisation.try(:id)}#{event_viewer_timezone_query(event)}&current_account=#{current_account ? 1 : 0}"
  end

  def event_block_carousel_cache_key(event)
    "/e/#{event.slug}/block_carousel?organisation_id=#{@organisation.try(:id)}#{event_viewer_timezone_query(event)}"
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
  # rows show (avatars and activity images) found in one query. An event's own pages pass an array of just it, which
  # preloading would only add queries for
  def with_stats_events(events)
    events = Event.preload_stats(events) unless events.is_a?(Array)
    accounts = events.flat_map { |event| [event.coordinator, event.organiser, event.revenue_sharer] }.compact.uniq
    images = accounts.filter_map { |account| account.image&.thumb('400x400#') } +
             events.filter_map(&:activity).uniq.filter_map { |activity| activity.image&.thumb('500x500#') }
    DragonflyJob.with_prefetched(images) { yield events }
  end

  # The stats page, or with table=1 just its table, which the page loads in a request of its own so it shows before the
  # rows are worked out
  def event_stats_page(organisation)
    params[:table] ? partial(:'events/event_stats', locals: { events: @events, organisation: organisation }) : erb(:'events/event_stats')
  end

  # The stats table's and CSV's columns, in order. Each is a cell partial (event_stats_row/) with its header and the
  # attributes of its th. table: false or csv: false leaves one out of the table or the CSV, a csv: block gives a
  # column's CSV text in place of its cell's, and revenue_admin: true columns are blank for events whose revenue the
  # viewer can't see
  def event_stats_columns(organisation)
    money = { 'data-money' => true }
    columns = [
      { name: 'name', csv: lambda(&:name) },
      { name: 'buttons', header: '', th: { 'data-orderable' => 'false' }, csv: false },
      { name: 'date', th: { style: 'min-width: 12.5em', 'data-col-name' => 'date' } },
      { name: 'coordinator' },
      { name: 'organiser', table: organisation.stripe_client_id.present? },
      { name: 'facilitators' },
      { name: 'tags' },
      { name: 'activity' },
      { name: 'local_group' },
      { name: 'facebook_event' },
      { name: 'views' },
      { name: 'tickets_sold', th: { 'data-sum' => true } },
      { name: 'checked_in' },
      { name: 'ticket_revenue', th: money },
      { name: 'donations', th: money }
    ]
    if organisation.stripe_client_id
      columns += [
        { name: 'ticket_revenue_to_revenue_sharer' },
        { name: 'ticket_revenue_to_organisation' },
        { name: 'revenue_reported_by_dandelion', header: 'Revenue reported by Dandelion' },
        { name: 'revenue_reported_by_stripe', header: 'Revenue reported by Stripe' },
        { name: 'stripe_fees' }
      ].map { |column| column.merge(th: money) }
      columns += [
        { name: 'profit' },
        { name: 'profit_less_donations_before_allocations', header: 'Profit less donations, before allocations' }
      ].map { |column| column.merge(th: money, revenue_admin: true) }
      # Allocated to a role = profit * profit_share_<role>
      columns += Event.profit_share_roles.map do |role|
        th = %w[category_steward social_media].include?(role) ? money.merge('data-hide-if-zero' => true) : money
        { name: "allocated_to_#{role}", partial: 'allocated_to_role', locals: { role: role }, th: th, revenue_admin: true }
      end
      columns += [
        { name: 'profit_less_donations_after_allocations', header: 'Profit less donations, after allocations' },
        { name: 'profit_including_donations_after_allocations', header: 'Profit including donations, after allocations' }
      ].map { |column| column.merge(th: money, revenue_admin: true) }
      columns += Event.profit_share_roles.map do |role|
        { name: "remaining_to_#{role}", csv: ->(event) { m(event.send("remaining_to_#{role}").abs, event.currency) }, table: false, revenue_admin: true }
      end
      columns << { name: 'remaining_to_be_paid', th: money, revenue_admin: true }
    end
    columns << { name: 'feedback' }
    columns.map { |column| { header: column[:name].humanize, partial: column[:name], locals: {}, th: {}, table: true, csv: true }.merge(column) }
  end

  def event_stats_table_columns(organisation)
    event_stats_columns(organisation).select { |column| column[:table] }
  end

  def event_stats_cell(column, event, organisation, revenue_admin)
    return '<td></td>' if column[:revenue_admin] && !revenue_admin

    partial(:"event_stats_row/#{column[:partial]}", locals: { event: event, organisation: organisation, **column[:locals] })
  end

  def event_stats_csv_cell(column, event, organisation, revenue_admin)
    return '' if column[:revenue_admin] && !revenue_admin
    return column[:csv].call(event) if column[:csv].respond_to?(:call)

    extract_csv_cell_text(event_stats_cell(column, event, organisation, revenue_admin))
  end

  # The stats table's rows
  def event_stats_rows(events, organisation)
    columns = event_stats_table_columns(organisation)
    with_stats_events(events) do |stats_events|
      stats_events.map do |event|
        revenue_admin = event_revenue_admin?(event)
        columns.map { |column| event_stats_cell(column, event, organisation, revenue_admin) }.join.html_safe
      end
    end
  end

  # The CSV's cells are the text of the stats table's cells (event_stats_row/), or their data-csv attribute
  def build_events_stats_csv(events, organisation)
    columns = event_stats_columns(organisation).select { |column| column[:csv] }
    CSV.generate do |csv|
      csv << columns.pluck(:name)
      with_stats_events(events) do |stats_events|
        stats_events.each do |event|
          revenue_admin = event_revenue_admin?(event)
          csv << columns.map { |column| event_stats_csv_cell(column, event, organisation, revenue_admin) }
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

  # The event's tickets the tickets and check-in lists show: those of params[:ticket_type_id] or params[:ticket_group_id]
  # if given, filtered by the list's checkboxes and searched by params[:q] (id, token, name, email or account)
  def event_tickets_from_params(*includes)
    tickets = if params[:ticket_type_id]
                (@event.ticket_types.find(params[:ticket_type_id]) || not_found).tickets
              elsif params[:ticket_group_id]
                (@event.ticket_groups.find(params[:ticket_group_id]) || not_found).tickets
              else
                @event.tickets
              end.includes(*includes)
    tickets = tickets.discounted if params[:discounted]
    tickets = tickets.deleted if params[:deleted]
    tickets = tickets.complete if params[:complete]
    tickets = tickets.incomplete if params[:incomplete]
    return tickets unless params[:q]

    q = /#{Regexp.escape(params[:q])}/i
    tickets.and(:id.in =>
      tickets.and(:$or => [{ id_string: q }, { token: q }, { name: q }, { email: q }]).pluck(:id) +
      tickets.and(:account_id.in => Account.search(params[:q], child_scope: tickets, regex_search: true).pluck(:id)).pluck(:id))
  end
end
