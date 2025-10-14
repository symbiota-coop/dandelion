Dandelion::App.controller do
  get '/g/:slug/budget' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @spend = Spend.new
    if request.xhr?
      partial :'budget/budget'
    else
      erb :'budget/budget'
    end
  end

  post '/g/:slug/spends/new' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @spend = @gathering.spends.new(mass_assigning(params[:spend], Spend))
    @spend.account = current_account unless @membership.admin?
    if @spend.save
      redirect back
    else
      erb :'budget/build'
    end
  end

  get '/g/:slug/spends/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @spend = @gathering.spends.find(params[:id]) || not_found
    erb :'budget/build'
  end

  post '/g/:slug/spends/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @spend = @gathering.spends.find(params[:id]) || not_found
    if @spend.update_attributes(mass_assigning(params[:spend], Spend))
      redirect "/g/#{@gathering.slug}/budget"
    else
      erb :'budget/build'
    end
  end

  get '/g/:slug/spends/:id/destroy' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @spend = @gathering.spends.find(params[:id]) || not_found
    @spend.destroy
    redirect "/g/#{@gathering.slug}/budget"
  end

  post '/spends/:id/reimbursed' do
    @spend = Spend.find(params[:id]) || not_found
    @gathering = @spend.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @spend.set(reimbursed: params[:reimbursed])
    200
  end

  post '/teams/:id/budget' do
    @team = Team.find(params[:id]) || not_found
    @gathering = @team.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @team.set(budget: params[:budget])
    200
  end

  get '/g/:slug/payments' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    erb :'budget/payments'
  end
end
