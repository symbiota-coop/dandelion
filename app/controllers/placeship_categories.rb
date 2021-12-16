Dandelion::App.controller do
  post '/placeship_categories/new' do
    sign_in_required!
    @placeship_category = current_account.placeship_categories.build(params[:placeship_category])
    if @placeship_category.save
      redirect "/u/#{current_account.username}#places"
    else
      flash.now[:error] = 'There was an error saving the category.'
      erb :'placeship_categories/build'
    end
  end

  get '/placeship/categorise/:id' do
    sign_in_required!
    @placeship = current_account.placeships.find(params[:id])
    partial :'placeship_categories/categorise', locals: { placeship: @placeship }
  end

  post '/placeship/categorise/:id' do
    sign_in_required!
    @placeship = current_account.placeships.find(params[:id])
    @placeship.update_attribute(:placeship_category_id, params[:placeship_category_id])
    200
  end

  get '/placeship_categories/:id/edit' do
    sign_in_required!
    @placeship_category = current_account.placeship_categories.find(params[:id]) || not_found
    erb :'placeship_categories/build'
  end

  post '/placeship_categories/:id/edit' do
    sign_in_required!
    @placeship_category = current_account.placeship_categories.find(params[:id]) || not_found
    if @placeship_category.update_attributes(mass_assigning(params[:placeship_category], PlaceshipCategory))
      redirect "/u/#{current_account.username}#places"
    else
      flash.now[:error] = 'There was an error saving the placeship_category.'
      erb :'placeship_categories/build'
    end
  end

  get '/placeship_categories/:id/destroy' do
    sign_in_required!
    @placeship_category = current_account.placeship_categories.find(params[:id]) || not_found
    @placeship_category.destroy
    redirect "/u/#{current_account.username}#places"
  end
end
