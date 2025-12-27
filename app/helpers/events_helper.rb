Dandelion::App.helpers do
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

  def apply_activity_local_group_filter(events, params)
    events = events.and(local_group_id: params[:local_group_id]) if params[:local_group_id]
    events = events.and(activity_id: params[:activity_id]) if params[:activity_id]
    events
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
