require 'faraday/follow_redirects'
require 'mini_magick'
require 'nokogiri'

module OrganisationCalendarImports
  extend ActiveSupport::Concern

  class ConfigurationError < StandardError; end

  LUMA_PAGE_HOSTS = %w[luma.com lu.ma].freeze
  LUMA_FEED_HOSTS = %w[api.luma.com api2.luma.com].freeze
  ALLOWED_FEED_HOSTS = [
    *LUMA_FEED_HOSTS,
    'calendar.google.com',
    'www.google.com',
    'outlook.office365.com',
    'outlook.live.com',
    'calendars.icloud.com'
  ].freeze
  # Luma's og:image uses this segment; we bump dimensions for a sharper stored cover.
  LUMA_OG_CDN_DIMENSIONS_DEFAULT = 'width=800,height=420'.freeze
  LUMA_OG_CDN_DIMENSIONS_IMPORT = 'width=1200,height=630'.freeze
  # In-person: strip "Address:" … + "Hosted by …". Online: keep "Get up-to-date information at: …", strip only trailing "Hosted by …".
  LUMA_DESCRIPTION_ADDRESS_FOOTER = /\n{1,2}Address:\s*\r?\n[\s\S]*?\r?\nHosted by .+$/m
  LUMA_DESCRIPTION_HOSTED_BY_AFTER_ONLINE_LINK = /\n{1,2}Hosted by .+$/m

  class_methods do
    def normalize_feed_url(feed_url)
      raise OrganisationCalendarImports::ConfigurationError, 'Add an iCal URL first' if feed_url.blank?

      uri = URI.parse(feed_url)
      raise OrganisationCalendarImports::ConfigurationError, 'iCal URL must include a host' if uri.host.blank?

      case uri.scheme&.downcase
      when 'http', 'https'
        # keep scheme
      when 'webcal'
        uri.scheme = 'https'
      else
        raise OrganisationCalendarImports::ConfigurationError, 'iCal URL must start with http, https or webcal'
      end

      host = uri.host.to_s.downcase
      raise OrganisationCalendarImports::ConfigurationError, "iCal host is not allowed (supported: #{OrganisationCalendarImports::ALLOWED_FEED_HOSTS.join(', ')})" unless OrganisationCalendarImports::ALLOWED_FEED_HOSTS.include?(host)

      uri.to_s
    rescue URI::InvalidURIError
      raise OrganisationCalendarImports::ConfigurationError, 'iCal URL must be a valid URL'
    end

    # X-WR-CALNAME (common) or RFC 7986 NAME (ip_name in icalendar).
    def calendar_name_from_parsed_calendars(calendars)
      Array(calendars).each do |cal|
        raw = cal.x_wr_calname&.first
        name = unwrap_ical_calendar_property_value(raw)
        return name if name.present?
      end
      Array(calendars).each do |cal|
        next unless cal.respond_to?(:ip_name)

        raw = cal.ip_name
        raw = raw.first if raw.is_a?(Array)
        name = unwrap_ical_calendar_property_value(raw)
        return name if name.present?
      end
      nil
    end

    def unwrap_ical_calendar_property_value(value)
      return if value.nil?

      value = value.value if value.respond_to?(:value)
      value.to_s.strip.presence
    end

    def valid_calendar_body?(body)
      text = body.to_s
      text.match?(/BEGIN:VCALENDAR\b/i) && text.match?(/END:VCALENDAR\b/i)
    end
  end

  def calendar_import_urls_a
    calendar_import_urls ? calendar_import_urls.split("\n").map(&:strip).reject(&:blank?) : []
  end

  def calendar_import_feeds_in_url_order
    names = (calendar_import_feed_calendar_names || {}).stringify_keys
    seen = {}
    calendar_import_urls_a.filter_map do |line|
      url = Organisation.normalize_feed_url(line)
      next if seen[url]

      seen[url] = true
      n = names[url]
      [url, n] if n.present?
    rescue OrganisationCalendarImports::ConfigurationError
      nil
    end
  end

  def sync_calendar_imports
    names_by_feed = (calendar_import_feed_calendar_names || {}).stringify_keys
    normalized_feed_urls = calendar_import_urls_a.filter_map do |u|
      Organisation.normalize_feed_url(u)
    rescue OrganisationCalendarImports::ConfigurationError
      nil
    end

    results = calendar_import_urls_a.map { |feed_url| sync_calendar_import_feed(feed_url) }
    errors = results.filter_map { |result| "#{result[:feed_url]}: #{result[:error]}" if result[:error] }

    results.each do |result|
      next if result[:error].present?
      next if result[:calendar_name].blank?

      names_by_feed[result[:feed_url].to_s] = result[:calendar_name]
    end
    names_by_feed.keep_if { |url, _| normalized_feed_urls.include?(url) }

    set(
      calendar_import_last_synced_at: Time.now,
      calendar_import_last_sync_error: errors.any? ? errors.join("\n") : nil,
      calendar_import_feed_calendar_names: names_by_feed
    )

    {
      created: results.sum { |result| result[:created] || 0 },
      updated: results.sum { |result| result[:updated] || 0 },
      skipped: results.sum { |result| result[:skipped] || 0 },
      removed: results.sum { |result| result[:removed] || 0 },
      feeds: results,
      errors: errors
    }
  end

  private

  def sync_calendar_import_feed(feed_url)
    normalized_feed_url = Organisation.normalize_feed_url(feed_url)

    response = Faraday.get(normalized_feed_url)
    raise OrganisationCalendarImports::ConfigurationError, "iCal feed returned #{response.status}" unless response.success?
    raise OrganisationCalendarImports::ConfigurationError, 'iCal feed did not return a VCALENDAR payload' unless Organisation.valid_calendar_body?(response.body)

    calendars = Icalendar::Calendar.parse(response.body)
    calendar_name = Organisation.calendar_name_from_parsed_calendars(calendars)

    @initial_calendar_import = !events.and(calendar_import_feed_url: normalized_feed_url).exists?

    created = 0
    updated = 0
    skipped = 0
    @present_import_event_ids = Set.new

    calendars.flat_map(&:events).each do |ical_event|
      case upsert_calendar_import_event(ical_event, feed_url: normalized_feed_url)
      when :created
        created += 1
      when :updated
        updated += 1
      else
        skipped += 1
      end
    end

    removed = destroy_absent_imported_events(normalized_feed_url)

    { created: created, updated: updated, skipped: skipped, removed: removed, feed_url: normalized_feed_url, calendar_name: calendar_name }
  rescue StandardError => e
    ErrorReporting.capture_exception(e, context: { organisation_id: id.to_s, calendar_import_url: feed_url }) unless e.is_a?(OrganisationCalendarImports::ConfigurationError)
    { error: e.message, feed_url: feed_url }
  end

  def upsert_calendar_import_event(ical_event, feed_url:)
    start_time = property_time(ical_event.dtstart)
    summary = property_text(ical_event.summary)

    luma_calendar_feed = begin
      uri = URI.parse(feed_url)
      LUMA_FEED_HOSTS.any? { |host| uri.host.to_s.casecmp(host).zero? }
    rescue URI::InvalidURIError
      false
    end

    url = property_text(ical_event.url).presence
    location_text = property_text(ical_event.location).presence
    description_text = property_text(ical_event.description)
    uid = property_text(ical_event.uid).presence

    source_url = url
    source_url ||= location_text if luma_event_page_url?(location_text)
    # In-person Luma events often omit URL and put the venue in LOCATION; UID still points at the event page.
    source_url = luma_event_url_from_uid(uid).presence if luma_calendar_feed && source_url.blank?

    event = find_existing_imported_event(feed_url: feed_url, uid: uid, source_url: source_url, summary: summary, start_time: start_time)
    return unpublish_cancelled_imported_event(event) if property_text(ical_event.status).to_s.casecmp('CANCELLED').zero?

    mark_present_imported(event) if event&.persisted?

    return :skipped unless start_time
    return :skipped if start_time < 1.day.ago
    return :skipped if summary.blank?

    end_time = property_time(ical_event.dtend)
    end_time ||= start_time + 1.hour
    end_time = start_time + 1.hour if end_time <= start_time

    event ||= events.new

    event_was_new = event.new_record?
    sync_account = account || admins.first

    event.organisation = self
    event.account ||= sync_account
    event.last_saved_by = sync_account
    event.prevent_notifications = true if @initial_calendar_import

    previous_theme_color = event.theme_color

    location_text_is_http_url = if location_text.present?
                                  begin
                                    uri = URI.parse(location_text.strip)
                                    uri.scheme.to_s.downcase.in?(%w[http https]) && uri.host.present?
                                  rescue URI::InvalidURIError
                                    false
                                  end
                                else
                                  false
                                end

    # Luma often puts the public event URL in LOCATION when the street address is gated ("Register to
    # see address"); GEO still reflects the real venue. Reverse-geocode GEO for a city label when we can.
    # Without GEO, URL-only LOCATION means online.
    import_location = if luma_calendar_feed && location_text_is_http_url
                        luma_ical_geo_lat_lon(ical_event).present? ? luma_location_label_from_ical_geo(ical_event) : 'Online'
                      else
                        location_text.presence || 'Online'
                      end

    import_description =
      if luma_calendar_feed && description_text.present?
        text = description_text.to_s.sub(LUMA_DESCRIPTION_ADDRESS_FOOTER, '')
        text = text.sub(LUMA_DESCRIPTION_HOSTED_BY_AFTER_ONLINE_LINK, '')
        text.strip
      else
        description_text
      end

    {
      name: summary,
      description: import_description,
      location: import_location,
      start_time: start_time,
      end_time: end_time,
      purchase_url: source_url,
      calendar_import_feed_url: feed_url,
      calendar_import_uid: uid,
      calendar_import_source_url: source_url,
      currency: currency
    }.each do |field, value|
      event.send("#{field}=", value)
    end

    if event.image.blank? && source_url && luma_event_page_url?(source_url)
      begin
        response = (@luma_og_html_faraday ||= Faraday.new do |f|
          f.response :follow_redirects, limit: 5, callback: lambda { |_response_env, new_request_env|
            raise OrganisationCalendarImports::ConfigurationError, 'Unexpected redirect host' unless luma_event_page_url?(new_request_env[:url].to_s)
          }
          f.adapter Faraday.default_adapter
        end).get(source_url) do |req|
          req.headers['Accept'] = 'text/html,application/xhtml+xml'
        end
        if response.success?
          doc = Nokogiri::HTML(response.body.to_s)
          candidates = doc.css('meta[property="og:image"], meta[property="og:image:secure_url"]')
                          .filter_map { |n| n['content']&.strip }
                          .reject(&:blank?)
                          .uniq
          luma_composite = candidates.find do |candidate|
            URI.parse(candidate).host.to_s.casecmp('og.luma.com').zero?
          rescue URI::InvalidURIError
            false
          end
          # Only fetch Luma's own CDN — avoids SSRF via arbitrary og:image URLs.
          if luma_composite.present?
            og_url = luma_composite.gsub(LUMA_OG_CDN_DIMENSIONS_DEFAULT, LUMA_OG_CDN_DIMENSIONS_IMPORT)
            event.image_url = og_url
          end
        end
      rescue StandardError, Dragonfly::Shell::CommandFailed
        nil
      end
    end

    if event.image.present? && event.image_changed?
      begin
        path = event.image.path
        if path && File.exist?(path)
          image = MiniMagick::Image.open(path)
          image.crop('1x1+0+0')
          pixel = image.get_pixels('RGB')[0][0]
          hex = format('#%02X%02X%02X', *pixel)
          event.theme_color = hex
        end
      rescue StandardError
        nil
      ensure
        image&.destroy! if image&.tempfile
      end
    end

    # Dragonfly sets image in before_save; Mongoid changed? stays false until then, so require image_changed?
    return :skipped unless event.new_record? || event.changed? || event.image_changed?

    event.calendar_import_last_synced_at = Time.now
    begin
      event.save!
    rescue Mongoid::Errors::Validations
      raise unless event.errors[:image].present?

      event.image = nil
      event.theme_color = previous_theme_color
      event.save!
    end
    mark_present_imported(event)
    event_was_new ? :created : :updated
  end

  def mark_present_imported(event)
    @present_import_event_ids.add(event.id) if event&.id
  end

  def destroy_absent_imported_events(normalized_feed_url)
    scope = events.and(calendar_import_feed_url: normalized_feed_url)
    keep = @present_import_event_ids.to_a
    to_destroy = keep.empty? ? scope : scope.and(:id.nin => keep)
    count = to_destroy.count
    to_destroy.each(&:destroy)
    count
  end

  def find_existing_imported_event(feed_url:, uid:, source_url:, summary:, start_time:)
    event = events.find_by(calendar_import_feed_url: feed_url, calendar_import_uid: uid) if uid
    event ||= events.find_by(calendar_import_feed_url: feed_url, calendar_import_source_url: source_url) if source_url
    event ||= events.find_by(calendar_import_feed_url: feed_url, name: summary, start_time: start_time) if summary.present? && start_time
    event
  end

  def unpublish_cancelled_imported_event(event)
    return :skipped unless event

    event.destroy
    :updated
  end

  def unwrap_property(property)
    property.respond_to?(:value) ? property.value : property
  end

  def property_text(property)
    unwrap_property(property)&.to_s&.strip
  end

  def property_time(property)
    return unless (value = unwrap_property(property))

    case value
    when Time
      value
    when DateTime
      Time.at(value.to_f).utc
    when Date
      Time.find_zone!(time_zone || ENV['DEFAULT_TIME_ZONE']).parse(value.to_s)
    when ->(v) { v.respond_to?(:to_datetime) }
      Time.at(value.to_datetime.to_f).utc
    when ->(v) { v.respond_to?(:to_time) }
      value.to_time
    end
  end

  # Returns [lat, lon] or nil (iCal GEO is latitude;longitude).
  def luma_ical_geo_lat_lon(ical_event)
    return unless ical_event.respond_to?(:geo)

    geo = unwrap_property(ical_event.geo)
    return if geo.blank?

    coords = geo.is_a?(Array) ? geo : Array(geo)
    return if coords.size < 2

    lat = coords[0].to_f
    lon = coords[1].to_f
    return unless lat.abs <= 90 && lon.abs <= 180 && !(lat.zero? && lon.zero?)

    [lat, lon]
  end

  # GeoNames vendored list; otherwise "In person". (GeonamesCityLookup memoizes the loaded TSV.)
  def luma_location_label_from_ical_geo(ical_event)
    lat, lon = luma_ical_geo_lat_lon(ical_event)
    return 'In person' unless lat && lon

    GeonamesCityLookup.nearest_city_name(lat, lon).presence || 'In person'
  rescue StandardError
    'In person'
  end

  # evt-xxx@events.lu.ma -> https://luma.com/event/evt-xxx (resolves to the public slug URL)
  def luma_event_url_from_uid(uid)
    return if uid.blank?

    m = /\A(evt-[a-zA-Z0-9]+)@events\.lu\.ma\z/i.match(uid.to_s.strip)
    return unless m

    "https://luma.com/event/#{m[1]}"
  end

  def luma_event_page_url?(url)
    uri = URI.parse(url)
    return false unless uri.scheme.to_s.downcase.in?(%w[http https])

    host = uri.host.to_s.downcase.sub(/\Awww\./, '')
    return false unless LUMA_PAGE_HOSTS.include?(host)

    return true if host == 'lu.ma'

    path = uri.path.to_s
    return true if path.include?('/event/')

    # https://luma.com/2j1ninpb (short slug; 307s like /event/evt-…)
    segments = path.split('/').reject(&:blank?)
    return false unless segments.length == 1

    seg = segments.first.downcase
    seg.match?(/\A[a-z0-9-]+\z/i)
  rescue URI::InvalidURIError
    false
  end
end
