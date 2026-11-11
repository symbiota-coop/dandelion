Dandelion::App.controller do
  get '/g/:slug/budget' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @spend = Spend.new
    if request.xhr?
      partial :'budget/budget'
    else
      erb :'budget/budget'
    end
  end

  post '/g/:slug/spends/new' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @spend = @gathering.spends.new(mass_assigning(params[:spend], Spend))
    @spend.account = current_account unless gathering_admin?
    if @spend.save
      redirect back
    else
      erb :'budget/build'
    end
  end

  get '/g/:slug/spends/:id/edit' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @spend = @gathering.spends.find(params[:id]) || not_found
    erb :'budget/build'
  end

  post '/g/:slug/spends/:id/edit' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @spend = @gathering.spends.find(params[:id]) || not_found
    spend_params = (params[:spend] || {}).dup
    spend_params.delete(:account_id) unless gathering_admin?
    if @spend.update_attributes(mass_assigning(spend_params, Spend))
      redirect "/g/#{@gathering.slug}/budget"
    else
      erb :'budget/build'
    end
  end

  post '/g/:slug/spends/:id/destroy' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @spend = @gathering.spends.find(params[:id]) || not_found
    @spend.destroy
    redirect "/g/#{@gathering.slug}/budget"
  end

  post '/g/:slug/spends/:id/reimbursed' do
    @gathering = gathering_from_params || not_found
    @spend = @gathering.spends.find(params[:id]) || not_found
    confirmed_membership_required!
    @spend.set(reimbursed: params[:reimbursed])
    200
  end

  post '/g/:slug/teams/:id/budget' do
    @gathering = gathering_from_params || not_found
    @team = @gathering.teams.find(params[:id]) || not_found
    confirmed_membership_required!
    @team.set(budget: params[:budget])
    200
  end

  get '/g/:slug/payments' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    erb :'budget/payments'
  end
end
