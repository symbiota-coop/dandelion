Dandelion::App.controller do
  get '/o/:slug/events_block' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @events = @organisation.events_for_search(include_locked: true, include_all_local_group_events: (true if params[:local_group_id])).future_and_current
    @events = @events.and(monthly_donors_only: true) if params[:members_events]
    partial :'organisations/events_block'
  end

  get '/o/:slug/events', provides: %i[html ics json] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @events = @organisation.events_for_search(include_locked: true, include_all_local_group_events: (true if params[:local_group_id]))
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @events = case params[:order]
              when 'created_at'
                @events.order('created_at desc')
              when 'featured'
                @events.order('featured desc, start_time asc')
              else
                @events.order('start_time asc')
              end
    q_ids = []
    q_ids += search_events(params[:q]).pluck(:id) if params[:q]
    event_tag_ids = []
    event_tag_ids = EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id) if params[:event_tag_id]
    event_ids = (!q_ids.empty? && !event_tag_ids.empty? ? (q_ids & event_tag_ids) : (q_ids + event_tag_ids))
    @events = @events.and(:id.in => event_ids) unless event_ids.empty?
    if params[:near] && (result = Geocoder.search(params[:near]).first)
      if result.respond_to?(:boundingbox)
        south, north, west, east = result.boundingbox.map(&:to_f)
      elsif result.respond_to?(:bounds)
        south, west, north, east = result.bounds.map(&:to_f)
      end
      @bounding_box = [[west, south], [east, north]]
      @events = @events.and(coordinates: { '$geoWithin' => { '$box' => @bounding_box } })
    end
    @events = @events.and(local_group_id: params[:local_group_id]) if params[:local_group_id]
    @events = @events.and(activity_id: params[:activity_id]) if params[:activity_id]
    carousel = nil
    if params[:carousel_id]
      @events = if params[:carousel_id] == 'featured'
                  @events.and(featured: true)
                else
                  carousel = Carousel.find(params[:carousel_id]) || not_found
                  @events.and(:id.in => EventTagship.and(:event_tag_id.in => carousel.event_tags.pluck(:id)).pluck(:event_id))
                end
    end
    unless params[:online] && params[:in_person]
      @events = @events.online if params[:online]
      @events = @events.in_person if params[:in_person]
    end
    @events = @events.and(monthly_donors_only: true) if params[:members_events]
    @events = @events.and(featured: true) if params[:featured]
    if params[:featured_or_course]
      @events = @events.and(:id.in =>
        @organisation.events.and(featured: true).pluck(:id) +
        @organisation.events.course.pluck(:id))
    end
    case content_type
    when :json
      @events = @events.live
      if params[:past] || (carousel && carousel.name.downcase.include?('past events'))
        @past = true
        @events = @events.past
      else
        @events = @events.future_and_current(@from)
        @events = @events.and(:start_time.lt => @to + 1) if @to
      end
      @events.map do |event|
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
    when :html
      if params[:past] || (carousel && carousel.name.downcase.include?('past events'))
        @past = true
        @events = @events.past
      else
        @events = @events.future_and_current(@from)
        @events = @events.and(:start_time.lt => @to + 1) if @to
      end
      if params[:order] == 'random'
        event_ids = @events.pluck(:id)
        @events = @events.collection.aggregate([
                                                 { '$match' => { '_id' => { '$in' => event_ids } } },
                                                 { '$sample' => { size: event_ids.length } }
                                               ]).map do |hash|
          Event.new(hash.select { |k, _v| Event.fields.keys.include?(k.to_s) })
        end
      end
      if request.xhr?
        if params[:display] == 'map'
          @lat = params[:lat]
          @lng = params[:lng]
          @zoom = params[:zoom]
          @south = params[:south]
          @west = params[:west]
          @north = params[:north]
          @east = params[:east]
          box = [[@west.to_f, @south.to_f], [@east.to_f, @north.to_f]]

          @events = @events.and(coordinates: { '$geoWithin' => { '$box' => box } }) unless @events.empty?
          @points_count = @events.count
          @points = @events.to_a
          partial :'maps/map', locals: { stem: "/o/#{@organisation.slug}/events", dynamic: true, points: @points, points_count: @points_count, centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom }
        else
          partial :'organisations/events'
        end
      else
        erb :'organisations/events', layout: (params[:minimal] ? 'minimal' : nil)
      end
    when :ics
      @events = @events.live
      @events = @events.current(1.month.ago).limit(500)
      cal = Icalendar::Calendar.new
      cal.append_custom_property('X-WR-CALNAME', @organisation.name)
      @events.each do |event|
        cal.event do |e|
          if @organisation.ical_full
            e.summary = event.name
            e.dtstart = event.start_time.utc.strftime('%Y%m%dT%H%M%SZ')
            e.dtend = event.end_time.utc.strftime('%Y%m%dT%H%M%SZ')
          else
            e.summary = (event.start_time.to_date == event.end_time.to_date ? event.name : "#{event.name} starts")
            e.dtstart = (event.start_time.to_date == event.end_time.to_date ? event.start_time.utc.strftime('%Y%m%dT%H%M%SZ') : Icalendar::Values::Date.new(event.start_time.to_date))
            e.dtend = (event.start_time.to_date == event.end_time.to_date ? event.end_time.utc.strftime('%Y%m%dT%H%M%SZ') : nil)
          end
          e.location = event.location
          e.description = %(#{ENV['BASE_URI']}/events/#{event.id})
          e.uid = event.id.to_s
        end
      end
      cal.to_ical
    end
  end

  get '/o/:slug/events/stats', provides: %i[html csv] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @start_or_end = (params[:start_or_end] == 'end' ? 'end' : 'start')
    @events = params[:deleted] || params[:exclude_co_hosted] ? @organisation.events : @organisation.events_including_cohosted
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order("#{@start_or_end}_time asc")
    q_ids = []
    q_ids += search_events(params[:q]).pluck(:id) if params[:q]
    event_tag_ids = []
    event_tag_ids = EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id) if params[:event_tag_id]
    event_ids = (!q_ids.empty? && !event_tag_ids.empty? ? (q_ids & event_tag_ids) : (q_ids + event_tag_ids))
    @events = @events.and(:id.in => event_ids) unless event_ids.empty?
    @events = @events.and(:"#{@start_or_end}_time".gte => @from)
    @events = @events.and(:"#{@start_or_end}_time".lt => @to + 1) if @to
    @events = @events.and(coordinator_id: params[:coordinator_id]) if params[:coordinator_id]
    @events = @events.and(coordinator_id: nil) if params[:no_coordinator]
    @events = @events.and(:id.nin => EventFacilitation.pluck(:event_id)) if params[:no_facilitators]
    unless params[:online] && params[:in_person]
      @events = @events.online if params[:online]
      @events = @events.in_person if params[:in_person]
    end
    @events = @events.and(local_group_id: params[:local_group_id]) if params[:local_group_id]
    @events = @events.and(activity_id: params[:activity_id]) if params[:activity_id]
    if params[:cohost_id]
      @cohost = Organisation.find(params[:cohost_id])
      @events = @events.and(:id.in => @cohost.cohosted_events.pluck(:id))
    end
    if params[:carousel_id]
      @events = if params[:carousel_id] == 'featured'
                  @events.and(featured: true)
                else
                  carousel = Carousel.find(params[:carousel_id]) || not_found
                  @events.and(:id.in => EventTagship.and(:event_tag_id.in => carousel.event_tags.pluck(:id)).pluck(:event_id))
                end
    end
    if params[:discrepancy]
      events_with_discrepancy = @events.select do |event|
        stripe_charges = event.stripe_charges.and(:balance_float.gt => 0, :order_id.nin => Order.and(transferred: true).pluck(:id))
        stripe_charges_money = stripe_charges.sum(&:balance)
        (stripe_charges_money - event.revenue).abs.cents >= 100
      end
      @events = @events.and(:id.in => events_with_discrepancy.pluck(:id))
    end
    @events = @events.deleted if params[:deleted]
    case content_type
    when :html
      erb :'events/event_stats'
    when :csv
      CSV.generate do |csv|
        headers = []
        headers << 'name'

        headers_basic = %w[date coordinator organiser facilitators tags activity local_group facebook_event 30d_views tickets_sold checked_in ticket_revenue donations]
        headers += headers_basic

        if @organisation.stripe_client_id
          headers_stripe_client_id = %w[ticket_revenue_to_revenue_sharer ticket_revenue_to_organisation revenue_reported_by_dandelion revenue_reported_by_stripe stripe_fees]
          headers += headers_stripe_client_id

          headers += %w[
            profit
            profit_less_donations_before_allocations
          ]
          Event.profit_share_roles.each do |role|
            headers << "allocated_to_#{role}"
          end
          headers += %w[
            profit_less_donations_after_allocations
            profit_including_donations_after_allocations
          ]
          Event.profit_share_roles.each do |role|
            headers << "remaining_to_#{role}"
          end
          headers << 'remaining_to_be_paid'
        end

        headers << 'feedback'

        csv << headers

        @events.each do |event|
          row = []
          row << event.name

          row += headers_basic.map do |header|
            partial(:"event_stats_row/#{header}", locals: { event: event, organisation: @organisation })
          end

          if @organisation.stripe_client_id
            row += headers_stripe_client_id.map do |header|
              partial(:"event_stats_row/#{header}", locals: { event: event, organisation: @organisation })
            end

            if event_revenue_admin?(event)
              row += [
                partial(:'event_stats_row/profit', locals: { event: event, organisation: @organisation }),
                partial(:'event_stats_row/profit_less_donations_before_allocations', locals: { event: event, organisation: @organisation })
              ]

              Event.profit_share_roles.each do |role|
                row << partial(:'event_stats_row/allocated_to_role', locals: { event: event, organisation: @organisation, role: role })
              end

              row += [
                partial(:'event_stats_row/profit_less_donations_after_allocations', locals: { event: event, organisation: @organisation }),
                partial(:'event_stats_row/profit_including_donations_after_allocations', locals: { event: event, organisation: @organisation })
              ]

              Event.profit_share_roles.each do |role|
                row << m(event.send("remaining_to_#{role}").abs, event.currency)
              end
              row << partial(:'event_stats_row/remaining_to_be_paid', locals: { event: event, organisation: @organisation })
            else
              row += 13.times.map { '' }
            end
          end

          row << partial(:'event_stats_row/feedback', locals: { event: event, organisation: @organisation })

          row.each_with_index do |cell, i|
            html = Nokogiri::HTML(cell)
            if html.search('td').empty?
              row[i] = cell
            else
              html.search('script').remove
              row[i] = html.search('td').children.text.split("\n").reject(&:blank?).map(&:strip).join(', ')
            end
          end
          csv << row
        end
      end
    end
  end
end
