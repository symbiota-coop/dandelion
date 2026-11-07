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

  # The accounts within reach of a map's box, as [id, [lng, lat]]: all those that might be in a hexagon that reaches
  # into it (account_map_hexes_in_box), reach being how far beyond the box, in the grid's units, that could be
  def account_map_accounts_near_box(accounts, west, south, east, north, reach)
    reach_south = account_map_mercator_lat(account_map_mercator_y(south) - reach)
    reach_north = account_map_mercator_lat(account_map_mercator_y(north) + reach)
    accounts.and(coordinates: { '$geoWithin' => { '$box' => [[west - reach, reach_south], [east + reach, reach_north]] } }).pluck(:id, :coordinates)
  end

  # How far beyond a map's box an account can be and still be in one of its hexagons of the given size: from the
  # account to its smallest hexagon's centre, from there to its hexagon's centre, and from there to the box
  def account_map_reach(size)
    ACCOUNT_MAP_HEX_SIZE + (2 * size)
  end

  # The accounts a map's box shows, as [id, hexagon], with hexagons of the given size: those in hexagons that reach
  # into the box, from accounts near it (account_map_accounts_near_box). A hexagon bigger than ACCOUNT_MAP_HEX_SIZE
  # takes in the smallest hexagons whose centres are in it, not the accounts themselves, so a zoomed out map tells no
  # more than the smallest hexagons do. Whether an account is found depends only on its hexagon and the box, so moving
  # the box within a hexagon changes nothing, however small the box
  def account_map_hexes_in_box(near, west, south, east, north, size)
    near.filter_map do |id, (lng, lat)|
      hex = account_map_hex(lng, lat, ACCOUNT_MAP_HEX_SIZE)
      hex = account_map_hex(*account_map_hex_point(hex, ACCOUNT_MAP_HEX_SIZE), size) if size != ACCOUNT_MAP_HEX_SIZE
      centre_lng, centre_lat = account_map_hex_point(hex, size)
      centre_y = account_map_mercator_y(centre_lat)
      # It reaches into the box if its centre is within its size of the box (taking in a little around its corners)
      [id, hex] if centre_lng.between?(west - size, east + size) &&
                   centre_y.between?(account_map_mercator_y(south) - size, account_map_mercator_y(north) + size)
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
      near = account_map_accounts_near_box(points, west, south, east, north, account_map_reach(ACCOUNT_MAP_HEX_SIZE))
      found = account_map_hexes_in_box(near, west, south, east, north, ACCOUNT_MAP_HEX_SIZE)
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
  # as an area with a count, not a point. Hexagons are ACCOUNT_MAP_HEX_SIZE, or 2, 4, 8... times it on a bigger map, so
  # they're ACCOUNT_MAP_HEX_PIXELS to twice that wide on screen (map.js sends the map's width in pixels) however far the
  # map is zoomed out; if more are occupied than MAP_POINTS_LIMIT, as on a tall map, they grow again
  def account_cells_map_json(accounts)
    west, south, east, north = %i[west south east north].map { |p| params[p].to_f }
    pixels_per_degree = (params[:width].to_i.positive? ? params[:width].to_i.clamp(1, 10_000) : 1000) / [(east - west).abs, 0.000001].max
    # A hexagon is √3 size wide
    size = ACCOUNT_MAP_HEX_SIZE
    size *= 2 while size < 90 && Math.sqrt(3) * size * pixels_per_degree < ACCOUNT_MAP_HEX_PIXELS

    # One query, taking in accounts within reach of hexagons up to twice as big, so they can grow once without another
    reach = account_map_reach(size * 2)
    near = account_map_accounts_near_box(accounts, west, south, east, north, reach)
    hexes = nil
    loop do
      hexes = account_map_hexes_in_box(near, west, south, east, north, size).map(&:last).tally
      break if hexes.length <= MAP_POINTS_LIMIT || size > 90

      size *= 2
      next unless account_map_reach(size) > reach

      reach = account_map_reach(size * 2)
      near = account_map_accounts_near_box(accounts, west, south, east, north, reach)
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
