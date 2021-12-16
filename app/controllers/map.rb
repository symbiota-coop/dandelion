Dandelion::App.controller do
  get '/map' do
    @lat = params[:lat]
    @lng = params[:lng]
    @zoom = params[:zoom]
    @south = params[:south]
    @west = params[:west]
    @north = params[:north]
    @east = params[:east]
    box = [[@west.to_f, @south.to_f], [@east.to_f, @north.to_f]]

    @places = []
    @accounts = []
    @local_groups = []

    if params[:u]
      @account = Account.find_by(username: params[:u]) || not_found
      @places = @account.places_following.order('name_transliterated asc')
    elsif params[:uncategorised_id]
      account = Account.find(params[:uncategorised_id]) || not_found
      @places = Place.order('created_at desc').and(:id.in => account.placeships.and(placeship_category_id: nil).pluck(:place_id))
    elsif params[:placeship_category_id]
      placeship_category = PlaceshipCategory.find(params[:placeship_category_id]) || not_found
      @places = Place.order('created_at desc').and(:id.in => placeship_category.placeships.pluck(:place_id))
    elsif params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id]) || not_found
      @accounts = params[:admin] && organisation_admin? ? Account.all : Account.mappable
      @accounts = if params[:monthly_donors]
                    @accounts.and(:id.in => @organisation.organisationships.and(:hide_membership.ne => true, :monthly_donation_method.ne => nil).pluck(:account_id))
                  else
                    @accounts.and(organisation_ids_public_cache: @organisation.id)
                  end
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id]) || not_found
      @accounts = params[:admin] && activity_admin? ? Account.all : Account.mappable
      @accounts = @accounts.and(:id.in => @activity.activityships.and(:hide_membership.ne => true).pluck(:account_id))
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id]) || not_found
      @accounts = params[:admin] && local_group_admin? ? Account.all : Account.mappable
      @accounts = @accounts.and(:id.in => @local_group.local_groupships.and(:hide_membership.ne => true).pluck(:account_id))
      @local_groups = [@local_group]
    elsif params[:place_id]
      @place = Place.find(params[:place_id]) || not_found
      @places = Place.and(id: @place.id)
      @accounts = Account.mappable.and(:id.in => @place.placeships.pluck(:account_id))
    else
      @places = Place.order('created_at desc')
      @accounts = Account.mappable
    end

    if request.xhr?
      @places = @places.and(coordinates: { '$geoWithin' => { '$box' => box } }) unless @places.empty?
      unless @accounts.empty?
        @accounts = @accounts.and(coordinates: { '$geoWithin' => { '$box' => box } })
        @accounts = @accounts.and(:number_at_this_location.lte => 50)
      end
      @points_count = @places.count + @accounts.count
      @points = @places + @accounts
      @polygonables = @local_groups
      partial :'maps/map', locals: { dynamic: true, points: @points, points_count: @points_count, polygonables: @polygonables, places: params[:places], centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom }
    else
      @places = @places.and(:coordinates.ne => nil) unless @places.empty?
      @accounts = @accounts.and(:coordinates.ne => nil) unless @accounts.empty?
      @points_count = @places.count + @accounts.count
      @points = @places + @accounts
      @polygonables = @local_groups
      @place = Place.new
      if params[:map_only]
        @no_intercom = true
        partial :'maps/map', locals: { points: @points, points_count: @points_count, polygonables: @polygonables, centre: (OpenStruct.new(lat: @lat, lng: @lng) if @lat && @lng), zoom: @zoom }, layout: :minimal
      elsif params[:blocks_only]
        @no_intercom = true
        if @account
          partial :'accounts/places', locals: { block_class: 'col-6' }, layout: :minimal
        else
          partial :'places/blocks', locals: { places: @places, block_class: 'col-6' }, layout: :minimal
        end
      else
        erb :'maps/map'
      end
    end
  end

  get '/map/trigger' do
    200
  end
end
