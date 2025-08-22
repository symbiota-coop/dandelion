Dandelion::App.controller do
  before do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @carousels = @organisation.carousels.order('o asc')
  end

  get '/o/:slug/carousels/new' do
    @carousel = Carousel.new(weeks: 8)
    erb :'carousels/build'
  end

  post '/o/:slug/carousels/new' do
    @carousel = Carousel.new(mass_assigning(params[:carousel], Carousel))
    @carousel.organisation = @organisation
    if @carousel.save
      flash[:notice] = %(The carousel was saved.)
      redirect "/o/#{@organisation.slug}/carousels"
    else
      erb :'carousels/build'
    end
  end

  get '/o/:slug/carousels/:carousel_id/edit' do
    @carousel = @carousels.find(params[:carousel_id]) || not_found
    erb :'carousels/build'
  end

  post '/o/:slug/carousels/:carousel_id/edit' do
    @carousel = @carousels.find(params[:carousel_id]) || not_found
    if @carousel.update_attributes(mass_assigning(params[:carousel], Carousel))
      flash[:notice] = 'The carousel was saved.'
      redirect "/o/#{@organisation.slug}/carousels"
    else
      erb :'carousels/build'
    end
  end

  get '/o/:slug/carousels/:carousel_id/destroy' do
    @carousel = @carousels.find(params[:carousel_id]) || not_found
    @carousel.destroy
    redirect "/o/#{@organisation.slug}/carousels"
  end

  post '/o/:slug/carousels/order' do
    params[:carousel_ids].each_with_index do |carousel_id, i|
      @organisation.carousels.find(carousel_id).set(o: i)
    end
    200
  end
end
