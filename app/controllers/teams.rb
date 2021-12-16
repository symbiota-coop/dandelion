Dandelion::App.controller do
  get '/g/:slug/teams/new' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @team = Team.new
    erb :'teams/build'
  end

  post '/g/:slug/teams/new' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @team = @gathering.teams.build(params[:team])
    @team.account = current_account
    if @team.save
      @team.teamships.create(account: current_account)
      redirect "/g/#{@gathering.slug}/teams/#{@team.id}"
    else
      erb :'teams/build'
    end
  end

  get '/g/:slug/teams' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    if request.xhr?
      partial :'teams/teams'
    else
      erb :'teams/teams'
    end
  end

  get '/g/:slug/teams/:id' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    if request.xhr?
      partial :'teams/team'
    else
      erb :'teams/team', layout: 'layouts/teams'
    end
  end

  get '/g/:slug/teams/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    erb :'teams/build'
  end

  post '/g/:slug/teams/:id/edit' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    if @team.update_attributes(mass_assigning(params[:team], Team))
      redirect "/g/#{@gathering.slug}/teams/#{@team.id}"
    else
      erb :'teams/build'
    end
  end

  get '/g/:slug/teams/:id/destroy' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    @team.destroy
    redirect "/g/#{@gathering.slug}/teams"
  end

  get '/teamships/create' do
    @team = Team.find(params[:team_id]) || not_found
    @gathering = @team.gathering
    confirmed_membership_required!
    Teamship.create(account: current_account, team_id: params[:team_id])
    redirect back
  end

  get '/teamships/:id/destroy' do
    @teamship = Teamship.find(params[:id]) || not_found
    @gathering = @teamship.team.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    halt unless (@teamship.account.id == current_account.id) || @membership.admin?
    @teamship.destroy
    redirect back
  end

  post '/g/:slug/teamships/new' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @teamship = @gathering.teamships.build(params[:teamship])
    if @teamship.save
      redirect "/g/#{@gathering.slug}/teams"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the teamship from being saved.'
      erb :'teams/teamship'
    end
  end

  get '/g/:slug/teams/:id/unsubscribe' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    @teamship = @team.teamships.find_by(account: current_account)
    redirect(@teamship ? "/teamships/#{@teamship.id}/unsubscribe" : "/g/#{@gathering.slug}/teams/#{@team.id}")
  end

  get '/teamships/:id/subscribe' do
    @teamship = Teamship.find(params[:id]) || not_found
    @team = @teamship.team
    @gathering = @teamship.team.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    halt unless (@teamship.account.id == current_account.id) || @membership.admin?
    partial :'teams/subscribe', locals: { teamship: @teamship }
  end

  get '/teamships/:id/set_subscribe' do
    @teamship = Teamship.find(params[:id]) || not_found
    @team = @teamship.team
    @gathering = @teamship.team.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    halt unless (@teamship.account.id == current_account.id) || @membership.admin?
    @teamship.update_attribute(:unsubscribed, nil)
    request.xhr? ? 200 : (flash[:notice] = "You'll now receive email notifications of new posts in #{@team.name}"; redirect('/accounts/subscriptions'))
  end

  get '/teamships/:id/unsubscribe' do
    @teamship = Teamship.find(params[:id]) || not_found
    @team = @teamship.team
    @gathering = @teamship.team.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    halt unless (@teamship.account.id == current_account.id) || @membership.admin?
    @teamship.update_attribute(:unsubscribed, true)
    @team.subscriptions.and(account: current_account).destroy_all
    request.xhr? ? 200 : (flash[:notice] = "OK! You won't receive emails about #{@team.name}"; redirect('/accounts/subscriptions'))
  end
end
