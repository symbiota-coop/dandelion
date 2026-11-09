class Location
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  field :name, type: String
  field :query, type: String
  field :events_count, type: Integer
  field :signal_group_link, type: String
  field :summary, type: String

  validates_uniqueness_of :name
  validates_http_url :signal_group_link

  def self.protected_attributes
    %w[summary]
  end

  # The box to search for events near a place: Geocoder's bounds for it, at least 25 km across, as [[west, south], [east, north]]
  def self.bounds_for(location_query)
    return nil unless location_query

    normalized_query = location_query.strip.downcase
    cache_key = "geocode-bounds:#{normalized_query}"
    if (cached_bounds = bounds_cache.read(cache_key))
      return cached_bounds
    end

    result = Geocoder.search(location_query).first
    return nil unless result

    bounds = nil
    if result.respond_to?(:boundingbox) && result.boundingbox
      bounds = true
      south, north, west, east = result.boundingbox.map(&:to_f)
    elsif result.respond_to?(:bounds) && result.bounds
      bounds = true
      if ['uk', 'united kingdom'].include?(location_query.downcase)
        south = 49.6740000
        west = -14.0155170
        north = 61.0610000
        east = 2.0919117
      else
        south, west, north, east = result.bounds.map(&:to_f)
      end
    end

    lat, lng = result.coordinates
    min_km = 25
    # Approximate degrees per kilometer (varies by latitude, but good enough for a 25km box)
    lat_offset = (min_km / 2) * 0.009 # ~1km = 0.009 degrees latitude
    lng_offset = (min_km / 2) * 0.009 / Math.cos(lat * Math::PI / 180) # Adjust for longitude compression at this latitude

    min_south = lat - lat_offset
    min_north = lat + lat_offset
    min_west = lng - lng_offset
    min_east = lng + lng_offset

    if bounds
      # Expand bounds if they're smaller than 25km
      south = [south, min_south].min
      north = [north, min_north].max
      west = [west, min_west].min
      east = [east, min_east].max
    else
      # Use the 25km box as fallback
      south = min_south
      north = min_north
      west = min_west
      east = min_east
    end

    bounds = [[west, south], [east, north]]
    bounds_cache.write(cache_key, bounds, expires_in: 30.days)
    bounds
  end

  def self.bounds_cache
    @bounds_cache ||= ActiveSupport::Cache::RedisCacheStore.new(url: ENV['REDIS_URL'])
  end

  def online?
    name == 'Online'
  end

  # Public events here, past and future, or nil if its place can't be found
  def area_events
    events = Event.live.publicly_visible.browsable
    if online?
      events.online
    elsif (bounding_box = self.class.bounds_for(query))
      events.and(coordinates: { '$geoWithin' => { '$box' => bounding_box } })
    end
  end

  # Upcoming public events here, as the location's page lists them
  def events
    (area_events || Event.live.publicly_visible.browsable).future
  end

  # The AI summary of the vibe of its events (markdown), made daily by late:errands. Keeps the last one if the model doesn't answer
  def generate_summary
    events = self.events.to_a
    return if events.empty?

    summary = Event.summarise(
      "Create a summary of these events, happening in #{online? ? 'online' : query}, in one paragraph of three sentences.
      Don't mention specific events, just give a general sense of the vibe.",
      events.sample(20),
      general_instructions: 'Return well-formatted markdown. Do not use italics. Do not use headers.'
    )
    set(summary: summary) if summary
  end
end
