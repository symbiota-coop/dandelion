Dandelion::App.controller do
  get '/point/:model/:id' do
    partial "maps/#{params[:model].underscore}".to_sym, object: params[:model].constantize.find(params[:id])
  end

  get '/places' do
    @places = Place.order('created_at desc').paginate(page: params[:places_page], per_page: 16)
    if request.xhr?
      partial :'places/places', locals: { places: @places }
    else
      erb :'places/places'
    end
  end

  post '/places/new' do
    sign_in_required!
    @place = current_account.places.build(params[:place])
    if @place.save
      placeship = current_account.placeships.find_by(place: @place) || current_account.placeships.create(place: @place)
      placeship.update_attribute(:unsubscribed, true)
      redirect '/map'
    else
      flash.now[:error] = 'There was an error saving the place.'
      erb :'maps/map'
    end
  end

  get '/places/:id' do
    @place = Place.find(params[:id]) || not_found
    erb :'places/place'
  end

  get '/places/:id/edit' do
    sign_in_required!
    @place = Place.find(params[:id]) || not_found
    halt(403) unless admin? || @place.account_id == current_account.id
    erb :'places/build'
  end

  post '/places/:id/edit' do
    sign_in_required!
    @place = Place.find(params[:id]) || not_found
    halt(403) unless admin? || @place.account_id == current_account.id
    if @place.update_attributes(mass_assigning(params[:place], Place))
      @place.notifications_as_notifiable.and(type: 'updated_place').destroy_all
      @place.notifications_as_notifiable.create! circle: @place, type: 'updated_place'
      redirect "/places/#{@place.id}"
    else
      flash.now[:error] = 'There was an error saving the place.'
      erb :'places/build'
    end
  end

  get '/places/:id/destroy' do
    sign_in_required!
    @place = Place.find(params[:id]) || not_found
    halt(403) unless admin? || @place.account_id == current_account.id
    @place.destroy
    redirect '/map'
  end

  get '/placeship/:id' do
    sign_in_required!
    @place = Place.find(params[:id]) || not_found
    case params[:f]
    when 'not_following'
      current_account.placeships.find_by(place: @place).try(:destroy)
    when 'follow_without_subscribing'
      placeship = current_account.placeships.find_by(place: @place) || current_account.placeships.create(place: @place)
      placeship.update_attribute(:unsubscribed, true)
    when 'follow_and_subscribe'
      placeship = current_account.placeships.find_by(place: @place) || current_account.placeships.create(place: @place)
      placeship.update_attribute(:unsubscribed, false)
    end
    request.xhr? ? (partial :'places/placeship', locals: { place: @place, btn_class: params[:btn_class] }) : redirect("/places/#{@place.id}")
  end
end
