Dandelion::App.controller do
  post '/g/:slug/options/new' do
    @gathering = gathering_from_params
    membership_required!
    params[:option].delete(:cost) if params[:option] && !gathering_admin?
    @option = @gathering.options.build(mass_assigning(params[:option], Option))
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
    @gathering = gathering_from_params
    membership_required!
    if request.xhr?
      partial :'options/options'
    else
      erb :'options/options'
    end
  end

  get '/g/:slug/options/:id' do
    @gathering = gathering_from_params
    membership_required!
    @option = @gathering.options.find(params[:id]) || not_found
    partial :'options/option_modal'
  end

  get '/g/:slug/options/:id/edit' do
    @gathering = gathering_from_params
    @membership = @gathering.memberships.find_by(account: current_account)
    @option = @gathering.options.find(params[:id]) || not_found
    @option.cost > 0 ? gathering_admins_only! : membership_required!
    request.xhr? ? partial(:'gatherings/modal_content', locals: { title: @option.name, form: :'options/build' }) : erb(:'options/build')
  end

  post '/g/:slug/options/:id/edit' do
    @gathering = gathering_from_params
    @membership = @gathering.memberships.find_by(account: current_account)
    @option = @gathering.options.find(params[:id]) || not_found
    @option.cost > 0 ? gathering_admins_only! : membership_required!
    params[:option].delete(:cost) if params[:option] && !gathering_admin?
    if @option.update_attributes(mass_assigning(params[:option], Option))
      redirect "/g/#{@gathering.slug}/options"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the option from being saved.'
      erb :'options/build'
    end
  end

  post '/g/:slug/options/:id/destroy' do
    @gathering = gathering_from_params
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @option = @gathering.options.find(params[:id]) || not_found
    @option.destroy
    redirect "/g/#{@gathering.slug}/options"
  end

  post '/g/:slug/optionships/create' do
    @gathering = gathering_from_params
    @option = @gathering.options.find(params[:option_id]) || not_found
    membership_required!
    # Admins add people to options that are by invitation, from /g/:slug/optionships/new
    halt 403 if @option.by_invitation
    Optionship.create(account: current_account, option_id: params[:option_id], gathering: @gathering)
    200
  end

  # Leaving an option (its pagelet), or an admin removing someone (the contribution form)
  post '/g/:slug/optionships/:id/destroy' do
    @gathering = gathering_from_params
    @optionship = @gathering.optionships.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    own_or_gathering_admins_only!(@optionship)
    @optionship.destroy
    request.xhr? ? 200 : redirect("/g/#{@gathering.slug}/options")
  end

  post '/g/:slug/optionships/new' do
    @gathering = gathering_from_params
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @optionship = @gathering.optionships.build(mass_assigning(params[:optionship], Optionship))
    if @optionship.save
      redirect "/g/#{@gathering.slug}/options"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the optionship from being saved.'
      erb :'options/optionship'
    end
  end

  get '/g/:slug/optionships/:id/edit' do
    @gathering = gathering_from_params
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @optionship = @gathering.optionships.find(params[:id]) || not_found
    if request.xhr?
      partial :'gatherings/modal_content', locals: { title: "#{@optionship.account.name}: #{@optionship.option.name}", form: :'options/optionship' }
    else
      erb :'options/optionship'
    end
  end

  post '/g/:slug/optionships/:id/edit' do
    @gathering = gathering_from_params
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @optionship = @gathering.optionships.find(params[:id]) || not_found
    if @optionship.update_attributes(mass_assigning(params[:optionship], Optionship))
      redirect "/g/#{@gathering.slug}/options"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the optionship from being saved.'
      erb :'options/optionship'
    end
  end
end
