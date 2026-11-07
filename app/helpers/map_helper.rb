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

  # Maps show accounts at about their neighbourhood, not where they are: in a grid of hexagons, ACCOUNT_MAP_HEX_SIZE
  # across from their centre to a corner (about 1 km in London), each account at the centre of the hexagon it's in.
  # The grid is laid out on the map as Google draws it (Web Mercator), so the hexagons look regular there; its units
  # are degrees of longitude, so they cover less ground away from the equator, as the map does. Hexagon (q, r) is in
  # axial coordinates (https://www.redblobgames.com/grids/hexagons/), with its corners pointing up and down
  def account_map_mercator_y(lat)
    lat = lat.to_f.clamp(-85, 85) * Math::PI / 180
    Math.log(Math.tan((Math::PI / 4) + (lat / 2))) * 180 / Math::PI
  end

  def account_map_mercator_lat(y)
    ((2 * Math.atan(Math.exp(y * Math::PI / 180))) - (Math::PI / 2)) * 180 / Math::PI
  end

  # The hexagon of the given size a point is in, [q, r]
  def account_map_hex(lng, lat, size)
    x = lng.to_f
    y = account_map_mercator_y(lat)
    q = ((Math.sqrt(3) / 3 * x) - (y / 3)) / size
    r = (2.0 / 3 * y) / size
    # Round to the nearest hexagon in cube coordinates, where q + r + s = 0, fixing whichever rounded furthest
    s = -q - r
    rq, rr, rs = [q, r, s].map(&:round)
    if (rq - q).abs > (rr - r).abs && (rq - q).abs > (rs - s).abs
      rq = -rr - rs
    elsif (rr - r).abs > (rs - s).abs
      rr = -rq - rs
    end
    [rq, rr]
  end

  # A point in hexagon (q, r), dx and dy from its centre in the grid's units, as [lng, lat]
  def account_map_hex_point(hex, size, dx = 0, dy = 0)
    q, r = hex
    x = (size * Math.sqrt(3) * (q + (r / 2.0))) + dx
    y = (size * 1.5 * r) + dy
    [x.round(6), account_map_mercator_lat(y).round(6)]
  end

  # The corners of hexagon (q, r), as [lat, lng]s
  def account_map_hex_corners(hex, size)
    (0..5).map do |i|
      angle = ((60 * i) - 30) * Math::PI / 180
      lng, lat = account_map_hex_point(hex, size, size * Math.cos(angle), size * Math.sin(angle))
      [lat, lng]
    end
  end

  # Where a map shows an account, [lng, lat] as it stores its coordinates: the centre of its hexagon
  def account_map_coordinates(coordinates)
    account_map_hex_point(account_map_hex(*coordinates, ACCOUNT_MAP_HEX_SIZE), ACCOUNT_MAP_HEX_SIZE)
  end

  # The accounts a map's box shows, as [id, hexagon], with hexagons of the given size: those whose hexagon's centre is
  # in the box. The query takes in everyone within a hexagon's reach of the box, then keeps those whose hexagon's centre
  # is in it, so which accounts it finds and how many depend only on their hexagons: moving the box within a hexagon
  # changes nothing, and an account shown in the box is always found by it
  def account_map_hexes_in_box(accounts, west, south, east, north, size)
    reach_south = account_map_mercator_lat(account_map_mercator_y(south) - size)
    reach_north = account_map_mercator_lat(account_map_mercator_y(north) + size)
    accounts.and(coordinates: { '$geoWithin' => { '$box' => [[west - size, reach_south], [east + size, reach_north]] } })
            .pluck(:id, :coordinates).filter_map do |id, (lng, lat)|
      hex = account_map_hex(lng, lat, size)
      centre_lng, centre_lat = account_map_hex_point(hex, size)
      [id, hex] if centre_lng.between?(west, east) && centre_lat.between?(south, north)
    end
  end

  # [lat, lng] for a point on a map, with accounts' locations as account_map_coordinates says
  def map_point_lat_lng(point)
    return [point.lat, point.lng] unless point.coordinates

    coordinates = point.is_a?(Account) || point.is_a?(ActivityApplication) ? account_map_coordinates(point.coordinates) : point.coordinates
    [coordinates[1], coordinates[0]]
  end

  # A map's points in its box, as JSON, one each, with accounts at their hexagons' centres (account_map_coordinates)
  def map_json(points)
    west, south, east, north = %i[west south east north].map { |p| params[p].to_f }
    model_name = points.klass.to_s
    point_hash = ->(id, (lng, lat), n) { { model_name: model_name, id: encrypt_map_id(model_name, id.to_s), lat: lat, lng: lng, n: n } }

    if points.klass == Account
      found = account_map_hexes_in_box(points, west, south, east, north, ACCOUNT_MAP_HEX_SIZE)
      points_count = found.length
      point_hashes = found.each_with_index.map { |(id, hex), n| point_hash.(id, account_map_hex_point(hex, ACCOUNT_MAP_HEX_SIZE), n) }
    else
      points = points.and(coordinates: { '$geoWithin' => { '$box' => [[west, south], [east, north]] } })
      points_count = points.count
      point_hashes = points_count <= MAP_POINTS_LIMIT ? points.pluck(:id, :coordinates).each_with_index.map { |(id, coordinates), n| point_hash.(id, coordinates, n) } : []
    end
    point_hashes = [] if points_count > MAP_POINTS_LIMIT

    {
      points: point_hashes,
      pointsCount: points_count
    }.to_json
  end

  # A map of many accounts in its box, as JSON: the hexagons they're in, each with its corners and how many are in it,
  # which map.js shades by how many, so a place many people share, like a town everyone gives as their location, reads
  # as an area with a count, not a point. When there'd be more than MAP_POINTS_LIMIT hexagons, as a map zoomed out over a
  # country might have, the grid's hexagons grow 2, 4, 8... times as wide until there aren't, so everyone is still
  # counted and the map needn't say there are too many
  def account_cells_map_json(accounts)
    west, south, east, north = %i[west south east north].map { |p| params[p].to_f }
    size = ACCOUNT_MAP_HEX_SIZE
    hexes = nil
    loop do
      hexes = account_map_hexes_in_box(accounts, west, south, east, north, size).map(&:last).tally
      break if hexes.length <= MAP_POINTS_LIMIT || size > 90

      size *= 2
    end

    {
      points: [],
      pointsCount: 0,
      cells: hexes.map do |hex, count|
        lng, lat = account_map_hex_point(hex, size)
        { lat: lat, lng: lng, count: count, corners: account_map_hex_corners(hex, size) }
      end
    }.to_json
  end
end
