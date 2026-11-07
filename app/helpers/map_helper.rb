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

  # Maps show accounts' locations rounded to a tenth of a degree (about 11 km north to south), about where their town
  # is, so they still show how many people are in an area without pinpointing anyone
  def account_map_coordinates(coordinates)
    coordinates.map { |c| c.to_f.round(1) }
  end

  # [lat, lng] for a point on a map, with accounts' locations rounded as account_map_coordinates says
  def map_point_lat_lng(point)
    return [point.lat, point.lng] unless point.coordinates

    coordinates = point.is_a?(Account) || point.is_a?(ActivityApplication) ? account_map_coordinates(point.coordinates) : point.coordinates
    [coordinates[1], coordinates[0]]
  end

  def map_json(points)
    box = [[params[:west].to_f, params[:south].to_f], [params[:east].to_f, params[:north].to_f]]
    points = points.and(coordinates: { '$geoWithin' => { '$box' => box } })

    points_count = points.count

    point_hashes = []
    if points_count <= MAP_POINTS_LIMIT
      model_name = points.klass.to_s
      accounts = points.klass == Account
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
