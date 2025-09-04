Dandelion::App.controller do
  get '/point/:model/:id' do
    partial :"maps/#{params[:model].underscore}", object: params[:model].constantize.find(params[:id])
  end

  get '/map', provides: %i[html json] do
    @lat = params[:lat]
    @lng = params[:lng]
    @zoom = params[:zoom]
    @south = params[:south]
    @west = params[:west]
    @north = params[:north]
    @east = params[:east]
    box = [[@west.to_f, @south.to_f], [@east.to_f, @north.to_f]]

    @accounts = []
    @local_groups = []

    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id]) || not_found
      @info_window = params[:admin] && organisation_admin?
      @accounts = Account.all
      @accounts = if params[:monthly_donors]
                    @accounts.and(:id.in => @organisation.organisationships.and(:hide_membership.ne => true, :monthly_donation_method.ne => nil).pluck(:account_id))
                  else
                    @accounts.and(organisation_ids_public_cache: @organisation.id)
                  end
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id]) || not_found
      @info_window = params[:admin] && activity_admin?
      @accounts = Account.and(:id.in => @activity.activityships.and(:hide_membership.ne => true).pluck(:account_id))
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id]) || not_found
      @info_window = params[:admin] && local_group_admin?
      @accounts = Account.and(:id.in => @local_group.local_groupships.and(:hide_membership.ne => true).pluck(:account_id))
      @local_groups = [@local_group]
    else
      @accounts = Account.all
    end

    case content_type
    when :json
      # For JSON requests, apply bounding box filtering
      unless @accounts.empty?
        @accounts = @accounts.and(coordinates: { '$geoWithin' => { '$box' => box } })
        @accounts = @accounts.and(:number_at_this_location.lte => 50)
      end
      @points_count = @accounts.count
      @points = @accounts
      @polygonables = @local_groups

      polygon_paths_data = []
      if @polygonables
        @polygonables.each do |polygonable|
          polygonable.polygons.each do |polygon|
            polygon_path = polygon.coordinates[0].map do |coordinate|
              { lat: coordinate[1], lng: coordinate[0] }
            end
            polygon_paths_data << polygon_path
          end
        end
      end

      {
        points: if @points.count > MAP_POINTS_LIMIT
                  []
                else
                  @points.map.with_index do |point, n|
                    {
                      model_name: point.class.to_s,
                      id: point.id.to_s,
                      lat: point.lat,
                      lng: point.lng,
                      n: n
                    }
                  end
                end,
        pointsCount: @points_count,
        polygonPaths: polygon_paths_data,
        polygonables: @polygonables,
        centre: (@lat && @lng ? { lat: @lat.to_f, lng: @lng.to_f } : nil),
        zoom: @zoom&.to_i,
        infoWindow: @info_window
      }.to_json
    else
      # HTML responses
      if request.xhr?
        unless @accounts.empty?
          @accounts = @accounts.and(coordinates: { '$geoWithin' => { '$box' => box } })
          @accounts = @accounts.and(:number_at_this_location.lte => 50)
        end
        @points_count = @accounts.count
        @points = @accounts
        @polygonables = @local_groups
        partial :'maps/map', locals: { dynamic: true, points: @points, points_count: @points_count, polygonables: @polygonables, centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom, info_window: @info_window }
      else
        @accounts = @accounts.and(:coordinates.ne => nil) unless @accounts.empty?
        @points_count = @accounts.count
        @points = @accounts
        @polygonables = @local_groups
        if params[:map_only]
          partial :'maps/map', locals: { points: @points, points_count: @points_count, polygonables: @polygonables, centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom, info_window: @info_window }, layout: :minimal
        else
          erb :'maps/map'
        end
      end
    end
  end

  get '/map/trigger' do
    200
  end
end
