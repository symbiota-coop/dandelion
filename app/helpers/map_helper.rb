Dandelion::App.helpers do
  def set_bounding_box
    return @bounding_box if defined?(@bounding_box)
    return nil unless params[:near] && params[:near] != 'online'
    return nil unless %w[north south east west].all? { |p| params[p].nil? }

    @bounding_box = GeocodeBounds.for(params[:near])
  end

  def encrypt_map_id(model_name, id)
    TokenEncryptor.encrypt("map:#{model_name}:#{id}")
  end

  def decrypt_map_id(token)
    data = TokenEncryptor.decrypt(token)
    return unless data&.start_with?('map:')

    parts = data.split(':', 3)
    return unless parts.length == 3

    { model_name: parts[1], id: parts[2] }
  end

  # Maps show accounts at about their town, not where they are: each account at the centre of the tenth-of-a-degree
  # cell (about 11 km north to south) it's in, so maps still show how many people are in an area without pinpointing
  # anyone. Cell k holds coordinates from k / 10 up to, but not including, (k + 1) / 10 (ACCOUNT_MAP_CELLS_PER_DEGREE)
  def account_map_cell(coordinate)
    cell = (coordinate.to_f * ACCOUNT_MAP_CELLS_PER_DEGREE).floor
    # Multiplying can land a coordinate on the far side of an edge, so check it against the edges as Mongo will
    cell -= 1 while coordinate < cell.to_f / ACCOUNT_MAP_CELLS_PER_DEGREE
    cell += 1 while coordinate >= (cell + 1).to_f / ACCOUNT_MAP_CELLS_PER_DEGREE
    cell
  end

  def account_map_coordinates(coordinates)
    coordinates.map { |c| ((account_map_cell(c) + 0.5) / ACCOUNT_MAP_CELLS_PER_DEGREE).round(2) }
  end

  # The accounts a map's box shows: those whose cell's centre is in the box, found by where they are in the cells, so
  # which accounts it finds and how many depend only on their cells. Moving the box within a cell changes nothing, and
  # an account shown in the box is always found by it
  def account_map_points_in_box(points, west, south, east, north)
    edges = [[west, east], [south, north]].map do |low, high|
      first = ((low * ACCOUNT_MAP_CELLS_PER_DEGREE) - 0.5).ceil
      last = ((high * ACCOUNT_MAP_CELLS_PER_DEGREE) - 0.5).floor
      [first.to_f / ACCOUNT_MAP_CELLS_PER_DEGREE, (last + 1).to_f / ACCOUNT_MAP_CELLS_PER_DEGREE] if first <= last
    end
    return points.none unless edges.all?

    (west_edge, east_edge), (south_edge, north_edge) = edges
    # $box includes its far edges, which belong to the next cells, so they're left out
    points.and(coordinates: { '$geoWithin' => { '$box' => [[west_edge, south_edge], [east_edge, north_edge]] } })
          .and('coordinates.0' => { '$lt' => east_edge }, 'coordinates.1' => { '$lt' => north_edge })
  end

  # [lat, lng] for a point on a map, with accounts' locations as account_map_coordinates says
  def map_point_lat_lng(point)
    return [point.lat, point.lng] unless point.coordinates

    coordinates = point.is_a?(Account) || point.is_a?(ActivityApplication) ? account_map_coordinates(point.coordinates) : point.coordinates
    [coordinates[1], coordinates[0]]
  end

  def map_json(points)
    west, south, east, north = %i[west south east north].map { |p| params[p].to_f }
    accounts = points.klass == Account
    points = if accounts
               account_map_points_in_box(points, west, south, east, north)
             else
               points.and(coordinates: { '$geoWithin' => { '$box' => [[west, south], [east, north]] } })
             end

    points_count = points.count

    point_hashes = []
    if points_count <= MAP_POINTS_LIMIT
      model_name = points.klass.to_s
      point_records = points.pluck(:id, :coordinates)

      point_hashes = point_records.map.with_index do |(id, coordinates), n|
        coordinates = account_map_coordinates(coordinates) if accounts
        {
          model_name: model_name,
          id: encrypt_map_id(model_name, id.to_s),
          lat: coordinates[1],
          lng: coordinates[0],
          n: n
        }
      end
    end

    {
      points: point_hashes,
      pointsCount: points_count
    }.to_json
  end
end
