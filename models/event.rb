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

  COPY_FIELDS = %w[
    name location email image
    description extra_info_for_ticket_email
    capacity
    last_saved_by
  ].freeze

  def copy_to(events)
    events.each do |event|
      COPY_FIELDS.each { |f| event.send("#{f}=", send(f)) }
      event.save!
    rescue StandardError => e
      Honeybadger.notify(e)
    end
  end

  after_save :bulk_update_activity_events
  def bulk_update_activity_events
    return unless activity && update_activity_events.to_s == '1'

    copy_to(activity.events.future.and(:id.ne => id))
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

  def to_param
    slug
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def self.recommend
    events_with_participant_ids = Event.live.publicly_visible.future.map do |event|
      [event.id.to_s, event.attendee_ids.map(&:to_s)]
    end

    # Clean up caches for non-recommendable accounts
    recommendable_ids = Account.recommendable.pluck(:id)
    purged = AccountRecommendationCache.where(:account_id.nin => recommendable_ids).delete_all
    puts "Purged #{purged} orphaned recommendation caches" if purged.positive?

    total = recommendable_ids.count
    Account.recommendable.each_with_index do |account, i|
      puts "#{i + 1}/#{total}" if ((i + 1) % 1000).zero?
      account.recommend_people!
      account.recommend_events!(events_with_participant_ids)
    end
  end

  def responsible_name
    if organiser && organisation && organisation.experimental?
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

  def future?(from = Date.today)
    start_time >= from
  end

  def past?(from = Date.today)
    start_time < from
  end

  def started?(from = Date.today)
    from >= start_time
  end

  def finished?(from = Date.today)
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
    capacity - tickets.count if capacity
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
    set(browsable: !minimal_only? && !organisation.hidden && (organisation.paid_up || ticket_types.exists?))
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

  after_save :set_hidden_from_homepage
  def set_hidden_from_homepage
    adult_words = %w[naked sex sexual sexuality erotic eros cock pussy anal orgasm ejaculation dmt psilocybin lsd iboga ayahuasca mescaline mdma ketamine]
    forbidden_phrases = ['friday night dance']

    name_words = name ? name.downcase.split : []
    tag_words = Array(tag_names_cache).flat_map { |tag| tag.to_s.downcase.split }
    name_matches_forbidden = forbidden_phrases.any? { |phrase| name&.downcase&.include?(phrase.downcase) }
    set(hidden_from_homepage: true) if adult_words.intersect?(name_words + tag_words) || name_matches_forbidden || (organisation && organisation.hide_from_homepage?)
  end
end
