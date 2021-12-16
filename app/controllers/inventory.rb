Dandelion::App.controller do
  get '/g/:slug/inventory' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @inventory_item = @gathering.inventory_items.build(params[:inventory_item])
    if request.xhr?
      partial :'inventory/inventory'
    else
      erb :'inventory/inventory'
    end
  end

  post '/g/:slug/inventory_items/new' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @inventory_item = @gathering.inventory_items.build(params[:inventory_item])
    @inventory_item.account = current_account
    if @inventory_item.save
      redirect "/g/#{@gathering.slug}/inventory"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the item from being saved.'
      erb :'inventory/build'
    end
  end

  get '/g/:slug/inventory_items/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @inventory_item = @gathering.inventory_items.find(params[:id]) || not_found
    erb :'inventory/build'
  end

  post '/g/:slug/inventory_items/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @inventory_item = @gathering.inventory_items.find(params[:id]) || not_found
    if @inventory_item.update_attributes(mass_assigning(params[:inventory_item], InventoryItem))
      redirect "/g/#{@gathering.slug}/inventory"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the inventory item from being saved.'
      erb :'inventory/build'
    end
  end

  get '/g/:slug/inventory_items/:id/destroy' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @inventory_item = @gathering.inventory_items.find(params[:id]) || not_found
    @inventory_item.destroy
    redirect "/g/#{@gathering.slug}/inventory"
  end

  post '/g/:slug/inventory_items/:id/provided' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @inventory_item = @gathering.inventory_items.find(params[:id]) || not_found
    @inventory_item.update_attribute(:responsible, params[:responsible_id])
    200
  end
end
