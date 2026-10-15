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

  def map_json(points)
    box = [[params[:west].to_f, params[:south].to_f], [params[:east].to_f, params[:north].to_f]]
    points = points.only(:coordinates).and(coordinates: { '$geoWithin' => { '$box' => box } })

    points_count = points.count

    point_hashes = []
    if points_count <= MAP_POINTS_LIMIT
      point_records = points.pluck(:id, :coordinates)

      model_name = points.klass.to_s
      point_hashes = point_records.map.with_index do |(id, coordinates), n|
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
