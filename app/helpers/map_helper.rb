Dandelion::App.helpers do
  def set_bounding_box
    return @bounding_box if defined?(@bounding_box)
    return nil unless params[:near] && params[:near] != 'online'
    return nil unless %w[north south east west].all? { |p| params[p].nil? }

    @bounding_box = Location.bounds_for(params[:near])
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

  # Where a map shows an account, [lng, lat] as it stores its coordinates: the centre of its smallest hexagon
  # (MapHexagons)
  def account_map_coordinates(coordinates)
    MapHexagons.point(MapHexagons.hex(*coordinates, MapHexagons::SIZE), MapHexagons::SIZE)
  end

  # Whether hexagon (q, r) of the given size reaches into a map's box: if its centre is within its size of the box
  # (taking in a little around its corners). It depends only on the hexagon and the box, so moving the box within a
  # hexagon changes nothing, however small the box, and narrowing it can't find where anyone is in one
  def account_map_hex_in_box?(hex, size, west, south, east, north)
    centre_lng, centre_lat = MapHexagons.point(hex, size)
    centre_y = MapHexagons.mercator_y(centre_lat)
    centre_lng.between?(west - size, east + size) && centre_y.between?(MapHexagons.mercator_y(south) - size, MapHexagons.mercator_y(north) + size)
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
      # Everyone whose hexagon might reach into the box: from an account to its hexagon's centre is up to a hexagon's
      # size, and from there to the box another
      reach = 2 * MapHexagons::SIZE
      south_reach = MapHexagons.mercator_lat(MapHexagons.mercator_y(south) - reach)
      north_reach = MapHexagons.mercator_lat(MapHexagons.mercator_y(north) + reach)
      near = points.and(coordinates: { '$geoWithin' => { '$box' => [[west - reach, south_reach], [east + reach, north_reach]] } }).pluck(:id, :coordinates)
      found = near.filter_map do |id, (lng, lat)|
        hex = MapHexagons.hex(lng, lat, MapHexagons::SIZE)
        [id, hex] if account_map_hex_in_box?(hex, MapHexagons::SIZE, west, south, east, north)
      end
      points_count = found.length
      point_hashes = found.each_with_index.map { |(id, hex), n| point_hash.(id, MapHexagons.point(hex, MapHexagons::SIZE), n) }
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

  # How many accounts are in each smallest hexagon, as { [q, r] => count }, from the hexagons accounts store (map_hex),
  # counted by the database, so a map never reads where anyone is. Accounts geocoded before they stored it are counted
  # from their coordinates
  def account_map_hex_counts(accounts)
    counts = Hash.new(0)
    Account.collection.aggregate([
                                   { '$match' => accounts.and(:map_hex.ne => nil).selector },
                                   { '$group' => { _id: '$map_hex', count: { '$sum' => 1 } } }
                                 ]).each { |row| counts[MapHexagons.from_key(row['_id'])] += row['count'] }
    accounts.and(map_hex: nil, :coordinates.ne => nil).pluck(:coordinates).each { |c| counts[MapHexagons.hex(*c, MapHexagons::SIZE)] += 1 }
    counts
  end

  # A map of many accounts in its box, as JSON: the hexagons they're in, each with its corners and how many are in it,
  # which map.js shades by how many, so a place many people share, like a town everyone gives as their location, reads
  # as an area with a count, not a point. Hexagons are MapHexagons::SIZE, or 2, 4, 8... times it on a bigger map, so
  # they're MapHexagons::PIXELS to twice that wide on screen (map.js sends the map's width in pixels) however far the
  # map is zoomed out; if more reaching into the box are occupied than MAP_POINTS_LIMIT, as on a tall map, they grow
  # again. A bigger hexagon takes in the smallest hexagons whose centres are in it, not the accounts themselves, so a
  # zoomed out map tells no more than the smallest hexagons do
  def account_cells_map_json(accounts)
    west, south, east, north = %i[west south east north].map { |p| params[p].to_f }
    pixels_per_degree = (params[:width].to_i.positive? ? params[:width].to_i.clamp(1, 10_000) : 1000) / [(east - west).abs, 0.000001].max
    # A hexagon is √3 size wide
    size = MapHexagons::SIZE
    size *= 2 while size < 90 && Math.sqrt(3) * size * pixels_per_degree < MapHexagons::PIXELS

    counts = account_map_hex_counts(accounts)
    hexes = nil
    loop do
      hexes = Hash.new(0)
      counts.each do |hex, count|
        hex = MapHexagons.hex(*MapHexagons.point(hex, MapHexagons::SIZE), size) if size != MapHexagons::SIZE
        hexes[hex] += count
      end
      hexes.select! { |hex, _count| account_map_hex_in_box?(hex, size, west, south, east, north) }
      break if hexes.length <= MAP_POINTS_LIMIT || size > 90

      size *= 2
    end

    {
      points: [],
      pointsCount: 0,
      cells: hexes.map do |hex, count|
        lng, lat = MapHexagons.point(hex, size)
        { lat: lat, lng: lng, count: count, corners: MapHexagons.corners(hex, size) }
      end
    }.to_json
  end
end
