class Event
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include Mongoid::Paranoia
  include EventFields
  include EventAssociations
  include EventCallbacks
  include EventScopes
  include EventSerialization
  include EventAccounting
  include EventDuplication
  include EventNotifications
  include EventOpenCollective
  include EventValidation
  include EventAccessControl
  include EventAtproto
  include Geocoded
  include Taggable

  taggable tagships: :event_tagships, tag_class: EventTag
  include ImageWithValidation
  include Searchable

  # Key associations for `public_data`, event cards (`events/blocks`), etc.
  def self.with_key_includes
    includes(:organisation, :activity, :local_group, cohostships: :organisation, event_facilitations: :account, event_tagships: :event_tag)
  end

  COPY_FIELDS = %w[
    name location email image
    description extra_info_for_ticket_email
    capacity
    last_saved_by
  ].freeze

  after_save :bulk_update_activity_events, if: -> { activity && update_activity_events.to_s == '1' }
  def bulk_update_activity_events
    activity.events.future.and(:id.ne => id).each do |event|
      COPY_FIELDS.each { |f| event.send("#{f}=", send(f)) }
      event.save!
    rescue StandardError => e
      ErrorReporting.capture_exception(e)
    end
  end
  handle_asynchronously :bulk_update_activity_events

  def self.fs(slug)
    find_by(slug: slug)
  end

  def self.publicly_visible
    self.and(secret: false)
  end

  def image_source(cohost)
    cohostship = cohost && cohostships.find_by(organisation: cohost)
    return cohostship if cohostship&.image
    return self if image

    nil
  end

  def self.search_fields
    %w[name description location tag_names_cache]
  end

  def self.search_scope
    live.publicly_visible.browsable.future(1.week.ago)
  end

  def to_param
    slug
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def self.recommend
    events_with_participant_ids = Event.live.publicly_visible.future.map do |event|
      [event.id.to_s, event.attendee_ids.compact.map(&:to_s).reject(&:blank?)]
    end

    # Clean up caches for non-recommendable accounts
    recommendable_ids = Account.recommendable.pluck(:id)
    purged = AccountRecommendationCache.and(:account_id.nin => recommendable_ids).delete_all
    puts "Purged #{purged} orphaned recommendation caches" if purged.positive?

    total = recommendable_ids.count
    Account.recommendable.each_with_index do |account, i|
      puts "#{i + 1}/#{total}" if ((i + 1) % 1000).zero?
      account.recommend_people!
      account.recommend_events!(events_with_participant_ids)
    end
  end

  def responsible_name
    if organiser && organisation && organisation.stripe_client_id
      organiser
    elsif revenue_sharer
      revenue_sharer
    else
      organisation
    end.name
  end

  def page_views_count
    PageView.or({ path: "/e/#{slug}" }, { path: "/events/#{id}" }).count
  end

  def donations_to_dandelion?
    !donations_to_organisation? && organisation.donations_to_dandelion? && (suggested_donation || ticket_types.any? { |ticket_type| (ticket_type.price && ticket_type.price > 0) || ticket_type.range }) ? true : false
  end

  def token
    Token.all.find { |token| token.symbol == currency }
  end

  def chain
    if currency == 'USD'
      Chain.object('Gnosis Chain')
    else
      token.try(:chain)
    end
  end

  def questions_a
    q = (questions || '').split("\n").map(&:strip).reject(&:blank?)
    q.empty? ? [] : q
  end

  def questions_a_from_orders
    questions_from_orders = orders.pluck(:answers).compact.map { |answers| answers.map { |q, _a| q } }.flatten.uniq
    (questions_a + questions_from_orders).uniq
  end

  def recording?
    past? && has_recording?
  end

  def summary
    start_time ? "#{name} (#{start_time.to_date})" : name
  end

  def feedback_questions_a
    q = (feedback_questions || '').split("\n").map(&:strip).reject(&:blank?)
    q.empty? ? [] : q
  end

  def questions_a_from_event_feedbacks
    questions_from_feedbacks = event_feedbacks.pluck(:answers).compact.map { |answers| answers.map { |q, _a| q } }.flatten.uniq
    (feedback_questions_a + questions_from_feedbacks).uniq
  end

  def future?(from = Date.today)
    return true if evergreen?

    start_time >= from
  end

  def past?(from = Date.today)
    return false if evergreen?

    start_time < from
  end

  def started?(from = Date.today)
    return false if evergreen?

    from >= start_time
  end

  def finished?(from = Date.today)
    return false if evergreen?

    end_time < from
  end

  def online?
    location == 'Online'
  end

  def in_person?
    location != 'Online'
  end

  def paid_tickets?
    ticket_types.any? { |ticket_type| (ticket_type.price && ticket_type.price > 0) || ticket_type.range }
  end

  def live?
    !locked?
  end

  def sales_closed_due_to_event_end?
    no_sales_after_end_time? && end_time && Time.now > end_time
  end

  def publicly_visible?
    !secret?
  end

  def sold_out?
    return true if sales_closed_due_to_event_end?

    ticket_types.exists? && ticket_types.and(hidden: false).all? do |ticket_type|
      ticket_type.number_of_tickets_available_in_single_purchase <= 0 ||
        ticket_type.sales_ended?
    end
  end

  def sold_out_due_to_sales_end?
    return true if sales_closed_due_to_event_end?

    ticket_types.exists? && ticket_types.and(hidden: false).all? do |ticket_type|
      ticket_type.sales_ended?
    end
  end

  def tickets_available?
    return false if sales_closed_due_to_event_end?

    ticket_types.exists? && ticket_types.and(hidden: false).any? do |ticket_type|
      ticket_type.number_of_tickets_available_in_single_purchase >= 1 &&
        !ticket_type.sales_ended?
    end
  end

  def places_remaining
    capacity - tickets.and(made_available_at: nil).count if capacity
  end

  def time_zone_or_default
    time_zone || organisation.try(:time_zone) || ENV['DEFAULT_TIME_ZONE']
  end

  def theme_color_or_organisation_theme_color
    theme_color || organisation.try(:theme_color)
  end

  after_save :clear_cache
  def clear_cache
    fragments.delete_all
  end

  def set_browsable
    set(browsable: !evergreen? && !minimal_only? && !organisation.hidden && (organisation.paid_up || ticket_types.exists?))
  end

  # Event uses Mongoid::Paranoia, so destroy is a soft delete.
  # Keep Dragonfly assets available for deleted events and only remove them
  # when the record is permanently removed via destroy!.
  after_remove :destroy_dragonfly_attachments!

  def destroy_dragonfly_attachments
    nil
  end

  def destroy_dragonfly_attachments!
    dragonfly_attachments.each_value(&:destroy!)
  end

  def carousel_name
    return unless organisation && organisation.carousels

    c = nil
    organisation.carousels.order('o desc').each do |carousel|
      next if carousel.name.downcase.include?('past events')

      intersection = event_tag_ids & carousel.event_tag_ids
      if intersection.any?
        c = carousel.name
        break
      end
    end
    c
  end

  def when_details(zone, with_zone: true)
    return unless start_time && end_time

    zone ||= time_zone_or_default
    zone = time_zone if time_zone && location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{start_time.strftime('%Z')} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_fs(:no_double_zeros)} #{z if with_zone}"
    else
      "#{start_time.to_date}, #{start_time.to_fs(:no_double_zeros)} – #{end_time.to_date}, #{end_time.to_fs(:no_double_zeros)} #{z if with_zone}"
    end
  end

  def concise_when_details(zone, with_zone: false)
    return unless start_time && end_time

    zone ||= time_zone_or_default
    zone = time_zone if time_zone && location != 'Online'
    zone = zone.name unless zone.is_a?(String)
    start_time = self.start_time.in_time_zone(zone)
    end_time = self.end_time.in_time_zone(zone)
    z = "#{start_time.strftime('%Z')} (UTC #{start_time.formatted_offset})"
    if start_time.to_date == end_time.to_date
      start_time.to_date
    else
      "#{start_time.to_date} – #{end_time.to_date} #{z if with_zone}"
    end
  end

  def refresh_sold_out_cache_and_notify_waitlist
    was_sold_out = sold_out_cache.nil? ? sold_out? : sold_out_cache
    now_sold_out = sold_out?
    clear_cache
    set(sold_out_cache: now_sold_out)
    set(sold_out_due_to_sales_end_cache: sold_out_due_to_sales_end?)
    send_waitlist_tickets_available if was_sold_out && !now_sold_out
  end

  def ical(order: nil)
    return nil if evergreen?

    event = self
    cal = Icalendar::Calendar.new
    cal.append_custom_property('METHOD', 'REQUEST') if order
    cal.event do |e|
      e.summary = (event.start_time.to_date == event.end_time.to_date ? event.name : "#{event.name} starts")
      e.dtstart = (event.start_time.to_date == event.end_time.to_date ? event.start_time.utc.strftime('%Y%m%dT%H%M%SZ') : Icalendar::Values::Date.new(event.start_time.to_date))
      e.dtend = (event.start_time.to_date == event.end_time.to_date ? event.end_time.utc.strftime('%Y%m%dT%H%M%SZ') : nil)
      e.transp = (event.start_time.to_date == event.end_time.to_date ? 'OPAQUE' : 'TRANSPARENT')
      e.location = event.location
      e.description = order ? %(#{ENV['BASE_URI']}/orders/#{order.id}) : %(#{ENV['BASE_URI']}/events/#{event.id})
      e.organizer = event.email
      e.uid = event.id.to_s
      if order
        e.status = 'CONFIRMED'
        e.attendee = Icalendar::Values::CalAddress.new(
          "mailto:#{order.account.email}",
          cn: order.account.email,
          role: 'REQ-PARTICIPANT',
          partstat: 'ACCEPTED',
          cutype: 'INDIVIDUAL'
        )
      end
    end
    cal
  end

  after_save :ai_tag
  def ai_tag
    return unless ENV['OPENROUTER_API_KEY']
    return if duplicate
    return if calendar_import_feed_url
    return unless event_tagships(true).empty?

    # tags = nil
    # 5.times do
    #   tags = OpenRouter.chat(prompt, max_tokens: 256, schema: {
    #                            type: 'object',
    #                            properties: {
    #                              tags: {
    #                                type: 'array',
    #                                description: 'List of tags'
    #                              }
    #                            },
    #                            required: ['tags'],
    #                            additionalProperties: false
    #                          })['tags']
    #   break if tags.all? { |tag| !tag.starts_with?('#') }
    # end
    # return unless tags

    # tags.map do |name|
    #   name.gsub('_', ' ').gsub('-', ' ').downcase
    # end.each do |name|

    prompt = "Provide a list of 5 tags for this event as a comma-separated list. No hashtags. Separate multiple words in a tag with spaces. If the event is a test event, just return some generic tags. Event details: \n\n# #{name}\n\n#{description}"

    content = nil
    5.times do
      content = OpenRouter.chat(prompt, max_tokens: 256)
      break if content && content.include?(', ') && !content.include?('#')
    end
    return unless content && content.include?(', ') && !content.include?('#')

    tag_names = content.split(':').last.strip.split(',').map(&:strip).map do |name|
      name.gsub('_', ' ').gsub('-', ' ').downcase
    end

    tag_names.each do |name|
      puts name
      if (event_tag = EventTag.find_or_create_by(name: name)).persisted?
        event_tagships.create(event_tag: event_tag)
      end
    end
    set(ai_tagged: true)
  end
  handle_asynchronously :ai_tag

  def feedback_preview_token
    TokenVerifier.generate("feedback_preview:#{id}")
  end

  def valid_feedback_preview_token?(token)
    TokenVerifier.verify(token) == "feedback_preview:#{id}"
  end

  after_save :set_hidden_from_homepage
  def set_hidden_from_homepage
    forbidden_words = ENV['FORBIDDEN_WORDS'] ? ENV['FORBIDDEN_WORDS'].split.map(&:strip).reject(&:empty?) : []
    forbidden_locations = ENV['FORBIDDEN_LOCATIONS'] ? ENV['FORBIDDEN_LOCATIONS'].split(',').map(&:strip).reject(&:empty?) : []

    name_words = name ? name.downcase.split : []
    tag_words = Array(tag_names_cache).flat_map { |tag| tag.to_s.downcase.split }

    name_forbidden = forbidden_words.intersect?(name_words + tag_words)
    location_forbidden = forbidden_locations.any? { |phrase| location&.downcase&.include?(phrase.downcase) }

    set(hidden_from_homepage: true) if name_forbidden || location_forbidden || (organisation && organisation.hide_from_homepage?)
  end

  def self.check_cohosts_cache_sync(fix: false)
    out_of_sync = []

    # Aggregate cohostships to compute expected cache for each event
    expected_caches = Cohostship.collection.aggregate([
                                                        {
                                                          '$group' => {
                                                            '_id' => '$event_id',
                                                            'cohost_ids' => { '$push' => '$organisation_id' }
                                                          }
                                                        }
                                                      ]).to_a.to_h { |doc| [doc['_id'], doc['cohost_ids']] }

    # Get events that either have cohostships OR have stale cache fields
    event_ids_with_caches = Event.and(:cohosts_ids_cache.ne => nil).pluck(:id)

    relevant_event_ids = (expected_caches.keys + event_ids_with_caches).uniq

    # Process in batches of 1000
    relevant_event_ids.each_slice(1000) do |batch_ids|
      Event.unscoped.in(id: batch_ids).each do |event|
        expected_ids = (expected_caches[event.id] || []).map(&:to_s).sort
        current_ids = (event.cohosts_ids_cache || []).map(&:to_s).sort

        next if current_ids == expected_ids

        out_of_sync << {
          event: event,
          current: current_ids,
          expected: expected_ids
        }

        next unless fix

        event.set(cohosts_ids_cache: expected_ids.map { |id| BSON::ObjectId.from_string(id) })
      end
    end

    out_of_sync
  end
end
