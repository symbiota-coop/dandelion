Dandelion::App.controller do
  post '/g/:slug/options/new' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @option = @gathering.options.build(params[:option])
    @option.account = current_account
    if @option.save
      redirect "/g/#{@gathering.slug}/options"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the option from being saved.'
      erb :'options/build'
    end
  end

  get '/g/:slug/tiers' do
    redirect "/g/#{params[:slug]}/options"
  end

  get '/g/:slug/accoms' do
    redirect "/g/#{params[:slug]}/options"
  end

  get '/g/:slug/transports' do
    redirect "/g/#{params[:slug]}/options"
  end

  get '/g/:slug/options' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!
    if request.xhr?
      partial :'options/options'
    else
      erb :'options/options'
    end
  end

  get '/g/:slug/options/:id' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    membership_required!
    @option = @gathering.options.find(params[:id])
    partial :'options/option_modal'
  end

  get '/g/:slug/options/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @option = @gathering.options.find(params[:id])
    erb :'options/build'
  end

  post '/g/:slug/options/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @option = @gathering.options.find(params[:id])
    if @option.update_attributes(mass_assigning(params[:option], Option))
      redirect "/g/#{@gathering.slug}/options"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the option from being saved.'
      erb :'options/build'
    end
  end

  get '/g/:slug/options/:id/destroy' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @option = @gathering.options.find(params[:id])
    @option.destroy
    redirect "/g/#{@gathering.slug}/options"
  end

  get '/optionships/create' do
    @option = Option.find(params[:option_id]) || not_found
    @gathering = @option.gathering
    membership_required!
    Optionship.create(account: current_account, option_id: params[:option_id], gathering: @gathering)
    200
  end

  get '/optionships/:id/destroy' do
    @optionship = Optionship.find(params[:id]) || not_found
    @gathering = @optionship.option.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    halt unless (@optionship.account.id == current_account.id) || @membership.admin?
    @optionship.destroy
    200
  end

  post '/g/:slug/optionships/new' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @optionship = @gathering.optionships.build(params[:optionship])
    if @optionship.save
      redirect "/g/#{@gathering.slug}/options"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the optionship from being saved.'
      erb :'options/optionship'
    end
  end

  get '/g/:slug/optionships/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @optionship = @gathering.optionships.find(params[:id])
    erb :'options/optionship'
  end

  post '/g/:slug/optionships/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @optionship = @gathering.optionships.find(params[:id])
    if @optionship.update_attributes(mass_assigning(params[:optionship], Optionship))
      redirect "/g/#{@gathering.slug}/options"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the optionship from being saved.'
      erb :'options/optionship'
    end
  end

  get '/g/:slug/optionships/:id/destroy' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @optionship = @gathering.optionships.find(params[:id])
    @optionship.destroy
    redirect "/g/#{@gathering.slug}/options"
  end
end
