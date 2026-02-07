Dandelion::App.controller do
  get '/o/:slug/events_block' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @events = @organisation.events_including_cohosted.public.future_and_current_featured.without_heavy_fields
    @events = @events.and(monthly_donors_only: true) if params[:members_events]
    partial :'organisations/events_block'
  end

  get '/o/:slug/events', provides: %i[html ics json], prefetch: true do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    @events = @organisation.events_including_cohosted.public
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @events = apply_events_order(@events)
    @events = apply_geo_filter(@events)
    @events = @events.and(local_group_id: params[:local_group_id]) if params[:local_group_id]
    @events = @events.and(activity_id: params[:activity_id]) if params[:activity_id]
    carousel = nil
    params[:carousel_ids] = [params[:carousel_id]] if params[:carousel_id]
    if params[:carousel_ids] && params[:carousel_ids].any?
      @events = if params[:carousel_ids].include?('featured')
                  @events.and(featured: true)
                else
                  event_tags = EventTag.and(:id.in => Carouselship.and(:carousel_id.in => params[:carousel_ids]).pluck(:event_tag_id))
                  @events.and(:id.in => EventTagship.and(:event_tag_id.in => event_tags.pluck(:id)).pluck(:event_id))
                end
    end
    @events = apply_online_in_person_filter(@events)
    @events = @events.and(monthly_donors_only: true) if params[:members_events]
    @events = @events.and(featured: true) if params[:featured]
    if params[:featured_or_course]
      @events = @events.and(:id.in =>
        @organisation.events.and(featured: true).pluck(:id) +
        @organisation.events.course.pluck(:id))
    end
    case content_type
    when :html
      @events = @events.without_heavy_fields
      if params[:past] || (carousel && carousel.name.downcase.include?('past events'))
        @past = true
        @events = @events.past
      else
        @events = @events.future_and_current_featured(@from)
        @events = @events.and(:start_time.lt => @to + 1) if @to
      end
      @events = filter_events_by_search_and_tags(@events)
      @events = @events.and(minimal_only: false) unless params[:minimal]
      @events = apply_random_or_trending_order(@events, @from)
      if request.xhr?
        partial(:'organisations/events')
      else
        erb(:'organisations/events', layout: (params[:minimal] ? 'minimal' : nil))
      end
    when :json
      if params[:display] == 'calendar'
        @events = @events.without_heavy_fields
        @events = @events.future(@from)
        @events = @events.and(:start_time.lt => @to + 1) if @to
        @events = @events.and(locked: false)
        @events = filter_events_by_search_and_tags(@events)
        calendar_json(@events)
      elsif params[:display] == 'map'
        @events = @events.without_heavy_fields
        @events = @events.future(@from)
        @events = @events.and(:start_time.lt => @to + 1) if @to
        @events = @events.and(locked: false)
        @events = filter_events_by_search_and_tags(@events)
        map_json(@events)
      else
        # Regular JSON response for events
        @events = @events.without(:extra_info_for_ticket_email, :embedding)
        @events = @events.live

        if params[:past] || (carousel && carousel.name.downcase.include?('past events'))
          @past = true
          @events = @events.past
        else
          @events = @events.future_and_current_featured(@from)
          @events = @events.and(:start_time.lt => @to + 1) if @to
        end
        @events = filter_events_by_search_and_tags(@events)
        @events.to_public_json
      end
    when :ics
      @events = @events.without_heavy_fields
      @events = @events.live
      @events = @events.future_and_current_featured(1.month.ago)
      @events = filter_events_by_search_and_tags(@events)
      @events = @events.limit(500)
      build_events_ical(@events, @organisation.name, ical_full: @organisation.ical_full)
    end
  end

  get '/o/:slug/events/stats', provides: %i[html csv] do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil
    @start_or_end = (params[:start_or_end] == 'end' ? 'end' : 'start')
    @events = params[:deleted] || params[:exclude_co_hosted] ? @organisation.events : @organisation.events_including_cohosted
    @events = @events.without_heavy_fields
    @events = params[:order] == 'created_at' ? @events.order('created_at desc') : @events.order("#{@start_or_end}_time asc")
    @events = @events.and(:"#{@start_or_end}_time".gte => @from)
    @events = @events.and(:"#{@start_or_end}_time".lt => @to + 1) if @to
    @events = @events.and(coordinator_id: params[:coordinator_id]) if params[:coordinator_id]
    @events = @events.and(coordinator_id: nil) if params[:no_coordinator]
    @events = @events.and(:id.nin => EventFacilitation.pluck(:event_id)) if params[:no_facilitators]
    @events = apply_online_in_person_filter(@events)
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
                  @events.and(:id.in => EventTagship.and(:event_tag_id.in => carousel.event_tag_ids).pluck(:event_id))
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
    @events = filter_events_by_search_and_tags(@events)
    case content_type
    when :html
      erb :'events/event_stats'
    when :csv
      build_events_stats_csv(@events, @organisation)
    end
  end
end
