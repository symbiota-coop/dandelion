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

  def apply_online_in_person_filter(events, params)
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

  def apply_events_order(events, params)
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

  def apply_geo_filter(events, params)
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
end
