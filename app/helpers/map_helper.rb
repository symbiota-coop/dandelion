Dandelion::App.helpers do
  def set_bounding_box
    return @bounding_box if defined?(@bounding_box)
    return nil unless params[:near] && params[:near] != 'online'
    return nil unless %w[north south east west].all? { |p| params[p].nil? }

    @bounding_box = calculate_geographic_bounding_box(params[:near])
  end

  def calculate_geographic_bounding_box(location_query)
    return nil unless location_query

    normalized_query = location_query.strip.downcase
    cache_key = "geocode-bounds:#{normalized_query}"
    if (cached_bounds = geocode_cache.read(cache_key))
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

    # Always ensure minimum 25km bounding box
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
    geocode_cache.write(cache_key, bounds, expires_in: 30.days)
    bounds
  end

  def geocode_cache
    @geocode_cache ||= ActiveSupport::Cache::MongoStore.new(nil, collection: 'geocode_cache')
  end

  def map_json(points)
    box = [[params[:west].to_f, params[:south].to_f], [params[:east].to_f, params[:north].to_f]]
    points = points.and(coordinates: { '$geoWithin' => { '$box' => box } })

    points_count = points.count
    {
      points: if points_count > MAP_POINTS_LIMIT
                []
              else
                points.only(:coordinates).map.with_index do |point, n|
                  {
                    model_name: point.class.to_s,
                    id: point.id.to_s,
                    lat: point.lat,
                    lng: point.lng,
                    n: n
                  }
                end
              end,
      pointsCount: points_count
    }.to_json
  end
end
