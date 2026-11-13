class Event
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  include WhenDetails
  include SlugLookup

  extend Dragonfly::Model
  include Mongoid::Paranoia
  include EventFields
  include EventAssociations
  include EventCallbacks
  include EventScopes
  include EventSerialization
  include EventAccounting
  include EventStats
  include EventDuplication
  include EventNotifications
  include EventOpenCollective
  include EventValidation
  include EventAccessControl
  include EventAtproto
  include EventCarouselIds
  include EventSummaries
  include Geocoded
  include Taggable

  taggable tagships: :event_tagships, tag: :event_tag
  include ImageWithValidation
  include AnalyticsProviders
  include Searchable

  # Key associations for `public_data`, event cards (`events/blocks`), etc.
  def self.with_key_includes
    includes(:organisation, :activity, :local_group, cohostships: :organisation, event_facilitations: :account, event_tagships: :event_tag)
  end

  def self.prewarmed_image_derivative_sizes
    %w[32x32 992x992]
  end

  def self.prewarm_opengraph_image_derivative?
    true
  end

  def self.protected_attributes
    %w[
      raw_description direct_charges donations_to_organisation trending carousel_ids atproto_uri fixed_contribution_gbp cap_gbp promotion_fee_gbp
      cohosts_ids_cache hosts_ids_cache
      sent_feedback_requests_at sent_reminders_at sent_star_reminders_at
      voyage_embedding ai_tagged sold_out_cache sold_out_due_to_sales_end_cache browsable
      calendar_import_feed_url calendar_import_uid calendar_import_source_url calendar_import_last_synced_at
      locked_error locked_error_provider page_views_count hidden_from_homepage
    ]
  end

  def self.virtual_attributes
    super + %w[update_activity_events]
  end

  def self.assignable_foreign_keys
    %w[coordinator_id organiser_id activity_id local_group_id gathering_id revenue_sharer_id]
  end

  MAX_FEEDBACK_HOURS_AFTER = 30 * 24

  COPY_FIELDS = %w[
    name location email image
    description extra_info_for_ticket_email
    capacity
    last_saved_by
  ].freeze

  after_save :bulk_update_activity_events, if: -> { update_activity_events.to_s == '1' && can_bulk_update_activity_events? }
  def bulk_update_activity_events
    return unless can_bulk_update_activity_events?

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
    cohostship = cohost && cohostships.detect { |c| c.organisation_id == cohost.id }
    return cohostship if cohostship&.image
    return self if image

    nil
  end

  def self.search_fields
    %w[name description location tag_names_cache]
  end

  # Its Atlas Search index maps name as autocomplete too, so searches match the start of a word in it (Searchable)
  def self.autocomplete_fields
    %w[name]
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

  # Each live, public, future event's id and its attendees' ids, as strings, for recommending events. One query for
  # all the events' tickets, rather than one per event (~1,000 queries, 6 seconds, on an account's first visit to
  # /recommendations/events)
  def self.participant_ids_for_recommendations
    event_ids = live.publicly_visible.future.pluck(:id)
    attendee_ids = Ticket.and(:event_id.in => event_ids, payment_completed: true, :account_id.ne => nil)
                         .pluck(:event_id, :account_id)
                         .group_by(&:first)
    event_ids.map do |event_id|
      [event_id.to_s, (attendee_ids[event_id] || []).map { |_event_id, account_id| account_id.to_s }.uniq]
    end
  end

  def self.recommend
    events_with_participant_ids = participant_ids_for_recommendations

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

  # Counts a view of the event page, until the event starts, so the count stays as it was when the event began
  def count_page_view
    return if start_time && start_time <= Time.now

    inc(page_views_count: 1)
  end

  def donations_to_dandelion?
    !donations_to_organisation? && organisation.donations_to_dandelion? && EventPaymentMethod.platform_donations_available?(self) && (suggested_donation || ticket_types.any? { |ticket_type| (ticket_type.price && ticket_type.price > 0) || ticket_type.range }) ? true : false
  end

  # The donation to Dandelion the checkout form starts with: a percentage of the tickets, after percentage discounts, a
  # smaller one when they come to more than DANDELION_DONATION_HIGHER_PRICE_UNITS of the currency's smallest unit (£249),
  # and at least that unit. Agent bookings add just that unit (default_dandelion_donation)
  DANDELION_DONATION_PERCENT = 5
  DANDELION_DONATION_HIGHER_PRICE_PERCENT = 2.5
  DANDELION_DONATION_HIGHER_PRICE_UNITS = 249

  # Above this, the tickets get the smaller percentage
  def dandelion_donation_higher_price_over
    smallest = FiatCurrency.minimum_unit_amount(currency)
    (smallest * DANDELION_DONATION_HIGHER_PRICE_UNITS).to_f if smallest
  end

  # The donation to Dandelion an agent booking adds unless told otherwise: the smallest one there can be, the currency's
  # smallest unit (£1). None for free tickets, so as not to make a free booking paid
  def default_dandelion_donation(ticket_total)
    smallest = FiatCurrency.minimum_unit_amount(currency)
    smallest.to_f if donations_to_dandelion? && smallest && ticket_total.positive?
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
    no_sales_after_end_time? && end_time.present? && Time.now > end_time
  end

  def publicly_visible?
    !secret?
  end

  def monthly_donor?(account)
    account && organisation.organisationships.find_by(:account => account, :monthly_donation_method.ne => nil)
  end

  def activity_member?(account)
    activity && account && activity.activityships.find_by(account: account)
  end

  # Why account can't book this event (:locked, :monthly_donors_only or :members_only), or nil if they can. Admins can
  # book a locked event: pass a block saying whether account admins it, or it's looked up
  def booking_restriction(account)
    return :locked if locked? && !(block_given? ? yield : Event.admin?(self, account))
    return :monthly_donors_only if monthly_donors_only && !monthly_donor?(account)

    :members_only if activity && activity.privacy != 'open' && !activity_member?(account)
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

  # The event page shows the event as sold out, with its own waitlist, rather than the checkout form: it's sold out,
  # and its ticket types have no waitlists of their own to join
  def shows_event_waitlist?
    sold_out? && !ticket_type_waitlists_available?
  end

  # The event's own waitlist can be joined, unless the event has turned it off
  def event_waitlist_open?
    shows_event_waitlist? && !hide_waitlist
  end

  def ticket_type_waitlists_available?
    allow_ticket_type_waitlists? &&
      !sales_closed_due_to_event_end? &&
      ticket_types.and(hidden: false).any? do |ticket_type|
        ticket_type.number_of_tickets_available_in_single_purchase <= 0 &&
          !ticket_type.sales_ended?
      end
  end

  def ticket_type_waiters(ticket_type_id: nil)
    type_ids = ticket_type_id ? [ticket_type_id] : ticket_type_ids
    Account.and(:id.in => TicketTypeWaitship.and(:ticket_type_id.in => type_ids).pluck(:account_id).compact.uniq)
  end

  # Memoised per instance so that remaining, group capacity, event capacity,
  # sold_out? and waitlist state share a single grouped count query.
  # Reset via reset_ticket_counts whenever a ticket changes.
  def ticket_counts
    @ticket_counts ||= tickets.and(made_available_at: nil).counts_by_type
  end

  def reset_ticket_counts
    remove_instance_variable(:@ticket_counts) if defined?(@ticket_counts)
  end

  # Ticket types are looked up from to_a rather than with ticket_types.detect: Mongoid only keeps an association's
  # documents once something has iterated all of them, and detect stops early, so each detect queried again.
  # Called for every ticket type on an event page, that was hundreds of queries for an event with dozens of types
  def slots_taken
    ticket_types_by_id = ticket_types.to_a.index_by(&:id)
    ticket_counts.sum do |type_id, count|
      next count unless type_id

      ticket_type = ticket_types_by_id[type_id]
      count * (ticket_type ? ticket_type.slots : 1)
    end
  end

  # Every ticket type takes one place, so places filled is the ticket count
  def one_place_per_ticket?
    ticket_types.to_a.all? { |ticket_type| ticket_type.slots == 1 }
  end

  def places_remaining
    capacity - slots_taken if capacity
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
    set(browsable: !evergreen? && !minimal_only? && (organisation.paid_up || ticket_types.exists?))
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

  def admin_list_hash
    {
      id: id.to_s,
      name: "#{name} (#{concise_when_details(nil)})",
      slug: slug
    }
  end

  def admin_orders
    orders.complete.includes(:account).order('created_at desc')
  end

  def admin_tickets
    tickets.complete.includes(:account, :ticket_type, :order).order('created_at desc')
  end

  # Once resales are off, tickets on resale go back in the ticket counts, as their places mustn't sell. Only those that
  # fit, though (Ticket#fits_back_in_counts?): the rest go back when their holds are let go (Ticket's after_destroy).
  # The most recently put on resale go back first, as a sale removes the oldest
  def put_back_tickets_on_resale_that_fit
    tickets.and(:made_available_at.ne => nil).order('made_available_at desc').each do |ticket|
      ticket.set(made_available_at: nil) if ticket.fits_back_in_counts?
    end
  end

  def refresh_sold_out_cache_and_notify_waitlist
    reset_ticket_counts
    # Nested ticket types save on assignment, before this event is validated,
    # so compute from the saved event rather than any unsaved edits here.
    return unless (saved_event = Event.find(id))

    was_sold_out = sold_out_cache.nil? ? saved_event.sold_out? : sold_out_cache
    now_sold_out = saved_event.sold_out?
    clear_cache
    set(sold_out_cache: now_sold_out, sold_out_due_to_sales_end_cache: saved_event.sold_out_due_to_sales_end?)
    saved_event.ticket_types.each(&:refresh_sold_out_cache_and_notify_waitlist)
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
      e.description = order ? %(#{ENV['BASE_URI']}/orders/#{order.public_id}) : %(#{ENV['BASE_URI']}/e/#{event.slug})
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

    prompt = "Provide a list of 5 tags for this event as a comma-separated list. No hashtags. Separate multiple words in a tag with spaces. If the event is a test event, just return some generic tags. Event details: \n\n# #{name}\n\n#{description}"

    content = nil
    5.times do
      content = OpenRouter.chat(prompt)
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
    populate_tag_names_cache
    clear_cache
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

  # The index behind Organisation#events_including_cohosted
  HOSTS_INDEX = 'hosts_ids_cache_1_deleted_at_1_secret_1_start_time_1'.freeze

  # Hints MongoDB to use an index, skipping query planning: for queries whose plans the planner can't keep cached, like
  # events_including_cohosted, whose best plan differs between small and large organisations. Indexes are created
  # directly in the database, so the hint is only given where the index exists (not in tests or most development
  # databases): hinting a missing index makes the query fail. Which indexes exist is checked once per process
  def self.hinted(index_name)
    existing_index_names.include?(index_name) ? hint(index_name) : all
  end

  # Not cached while the collection doesn't exist (listing its indexes raises NamespaceNotFound), as in a fresh test database
  def self.existing_index_names
    @existing_index_names ||= collection.indexes.map { |index| index['name'] }
  rescue Mongo::Error::OperationFailure => e
    raise unless e.code == 26

    []
  end

  def self.reset_existing_index_names!
    @existing_index_names = nil
  end

  def hosts_ids_for(cohosts_ids)
    [organisation_id, *cohosts_ids].compact.uniq
  end

  # Checks hosts_ids_cache against organisation_id and cohosts_ids_cache, so run check_cohosts_cache_sync first.
  # Compares in the database and loads only the events out of sync
  def self.check_hosts_cache_sync(fix: false)
    ids = Event.collection.aggregate([
      { '$project' => {
        'hosts_ids_cache' => 1,
        'expected' => { '$setUnion' => [{ '$filter' => {
          'input' => { '$concatArrays' => [['$organisation_id'], { '$ifNull' => ['$cohosts_ids_cache', []] }] },
          'cond' => { '$ne' => ['$$this', nil] }
        } }] }
      } },
      { '$match' => { '$expr' => { '$or' => [
        { '$not' => [{ '$isArray' => '$hosts_ids_cache' }] },
        { '$ne' => [sorted_ids('$hosts_ids_cache'), sorted_ids('$expected')] }
      ] } } },
      { '$project' => { '_id' => 1 } }
    ]).map { |doc| doc['_id'] }

    Event.unscoped.in(id: ids).only(:name, :slug, :deleted_at, :organisation_id, :cohosts_ids_cache, :hosts_ids_cache).map do |event|
      expected = event.hosts_ids_for(event.cohosts_ids_cache)
      entry = { event: event, current: (event.hosts_ids_cache || []).map(&:to_s), expected: expected.map(&:to_s) }
      event.set(hosts_ids_cache: expected) if fix
      entry
    end
  end

  # Compares in the database and loads only the events out of sync
  def self.check_cohosts_cache_sync(fix: false)
    rows = Event.collection.aggregate([
      { '$project' => { 'cohosts_ids_cache' => 1 } },
      { '$lookup' => { 'from' => 'cohostships', 'localField' => '_id', 'foreignField' => 'event_id', 'as' => 'cohostships',
                       'pipeline' => [{ '$project' => { 'organisation_id' => 1 } }] } },
      { '$project' => { 'current' => sorted_ids('$cohosts_ids_cache'), 'expected' => sorted_ids('$cohostships.organisation_id') } },
      { '$match' => { '$expr' => { '$ne' => ['$current', '$expected'] } } }
    ]).to_a
    events = Event.unscoped.in(id: rows.pluck('_id')).index_by(&:id)

    rows.filter_map do |row|
      next unless (event = events[row['_id']])

      if fix
        cohosts_ids = row['expected']
        event.set(cohosts_ids_cache: cohosts_ids, hosts_ids_cache: event.hosts_ids_for(cohosts_ids))
      end
      { event: event, current: row['current'].map(&:to_s).sort, expected: row['expected'].map(&:to_s).sort }
    end
  end

  # An aggregation expression for the ids at path, sorted, treating a missing or null field as none
  def self.sorted_ids(path)
    { '$sortArray' => { 'input' => { '$ifNull' => [path, []] }, 'sortBy' => 1 } }
  end
  private_class_method :sorted_ids
end
