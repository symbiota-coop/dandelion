Dandelion::App.helpers do
  def calendar_json(events)
    user_time_zone = current_account ? current_account.time_zone : session[:time_zone]
    events.map do |event|
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

  def events_json(events)
    events.includes(:activity, :local_group).map do |event|
      {
        id: event.id.to_s,
        slug: event.slug,
        name: event.name,
        cohosts: event.cohosts.map { |organisation| { name: organisation.name, slug: organisation.slug } },
        facilitators: event.event_facilitators.map { |account| { name: account.name, username: account.username } },
        activity: event.activity ? { name: event.activity.name, id: event.activity_id.to_s } : nil,
        local_group: event.local_group ? { name: event.local_group.name, id: event.local_group_id.to_s } : nil,
        email: event.email,
        tags: event.event_tags.map(&:name),
        start_time: event.start_time,
        end_time: event.end_time,
        location: event.location,
        time_zone: event.time_zone,
        image: event.image ? event.image.thumb('1920x1920').url : nil,
        description: event.description
      }
    end.to_json
  end

  def filter_events_by_search_and_tags(events)
    q_ids = []
    q_ids += Event.search(params[:q], events).pluck(:id) if params[:q]
    event_tag_ids = []
    if params[:event_type]
      event_tag_ids = if (event_tag = EventTag.find_by(name: params[:event_type]))
                        event_tag.event_tagships.pluck(:event_id)
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

  def apply_random_or_trending_order(events, from)
    case params[:order]
    when 'random'
      event_ids = events.pluck(:id)
      events.collection.aggregate([
                                    { '$match' => { '_id' => { '$in' => event_ids } } },
                                    { '$sample' => { size: event_ids.length } }
                                  ]).map do |hash|
        Event.new(hash.select { |k, _v| Event.fields.keys.include?(k.to_s) })
      end
    when 'trending'
      events.trending(from)
    else
      events
    end
  end

  def apply_geo_filter(events)
    return events unless params[:near]

    if params[:near] == 'online'
      events.online
    elsif %w[north south east west].all? { |p| params[p].nil? } && (bounding_box = calculate_geographic_bounding_box(params[:near]))
      events.and(coordinates: { '$geoWithin' => { '$box' => bounding_box } })
    else
      events
    end
  end

  def build_events_ical(events, calendar_name, ical_full: false)
    cal = Icalendar::Calendar.new
    cal.append_custom_property('X-WR-CALNAME', calendar_name)
    events.each do |event|
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
        e.description = "#{ENV['BASE_URI']}/events/#{event.id}"
        e.uid = event.id.to_s
      end
    end
    cal.to_ical
  end

  def build_events_stats_csv(events, organisation)
    CSV.generate do |csv|
      headers = ['name']
      headers_basic = %w[date coordinator organiser facilitators tags activity local_group facebook_event 30d_views tickets_sold checked_in ticket_revenue donations]
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

      events.each do |event|
        row = [event.name]
        row += headers_basic.map { |h| partial(:"event_stats_row/#{h}", locals: { event: event, organisation: organisation }) }

        if organisation.stripe_client_id
          row += headers_stripe_client_id.map { |h| partial(:"event_stats_row/#{h}", locals: { event: event, organisation: organisation }) }
          if event_revenue_admin?(event)
            row += [
              partial(:'event_stats_row/profit', locals: { event: event, organisation: organisation }),
              partial(:'event_stats_row/profit_less_donations_before_allocations', locals: { event: event, organisation: organisation })
            ]
            Event.profit_share_roles.each { |role| row << partial(:'event_stats_row/allocated_to_role', locals: { event: event, organisation: organisation, role: role }) }
            row += [
              partial(:'event_stats_row/profit_less_donations_after_allocations', locals: { event: event, organisation: organisation }),
              partial(:'event_stats_row/profit_including_donations_after_allocations', locals: { event: event, organisation: organisation })
            ]
            Event.profit_share_roles.each { |role| row << m(event.send("remaining_to_#{role}").abs, event.currency) }
            row << partial(:'event_stats_row/remaining_to_be_paid', locals: { event: event, organisation: organisation })
          else
            row += 13.times.map { '' }
          end
        end

        row << partial(:'event_stats_row/feedback', locals: { event: event, organisation: organisation })
        row.map! { |cell| extract_csv_cell_text(cell) }
        csv << row
      end
    end
  end

  def extract_csv_cell_text(cell)
    html = Nokogiri::HTML(cell)
    return cell if html.search('td').empty?

    html.search('script').remove
    html.search('td').children.text.split("\n").reject(&:blank?).map(&:strip).join(', ')
  end
end
