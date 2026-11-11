Dandelion::App.controller do
  get '/g/:slug/teams/new' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @team = Team.new
    erb :'teams/build'
  end

  post '/g/:slug/teams/new' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @team = @gathering.teams.build(mass_assigning(params[:team], Team))
    @team.account = current_account
    if @team.save
      @team.teamships.create(account: current_account, gathering: @gathering)
      redirect "/g/#{@gathering.slug}/teams/#{@team.id}"
    else
      erb :'teams/build'
    end
  end

  get '/g/:slug/teams' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    if request.xhr?
      partial :'teams/teams'
    else
      erb :'teams/teams'
    end
  end

  get '/g/:slug/teams/:id' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    if request.xhr?
      partial :'teams/team'
    else
      erb :'teams/team', layout: 'layouts/teams'
    end
  end

  get '/g/:slug/teams/:id/edit' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    erb :'teams/build'
  end

  post '/g/:slug/teams/:id/edit' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    if @team.update_attributes(mass_assigning(params[:team], Team))
      redirect "/g/#{@gathering.slug}/teams/#{@team.id}"
    else
      erb :'teams/build'
    end
  end

  post '/g/:slug/teams/:id/destroy' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    @team.destroy
    redirect "/g/#{@gathering.slug}/teams"
  end

  post '/g/:slug/teamships/create' do
    @gathering = gathering_from_params || not_found
    @team = @gathering.teams.find(params[:team_id]) || not_found
    confirmed_membership_required!
    Teamship.create(account: current_account, team: @team, gathering: @gathering)
    redirect back
  end

  post '/g/:slug/teamships/:id/destroy' do
    @gathering = gathering_from_params || not_found
    @teamship = @gathering.teamships.find(params[:id]) || not_found
    confirmed_membership_required!
    own_or_gathering_admins_only!(@teamship)
    @teamship.destroy
    redirect back
  end

  post '/g/:slug/teamships/new' do
    @gathering = gathering_from_params || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @teamship = @gathering.teamships.build(mass_assigning(params[:teamship], Teamship))
    if @teamship.save
      redirect "/g/#{@gathering.slug}/teams"
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the teamship from being saved.'
      erb :'teams/teamship'
    end
  end

  get '/g/:slug/teams/:id/unsubscribe' do
    @gathering = gathering_from_params || not_found
    confirmed_membership_required!
    @team = @gathering.teams.find(params[:id]) || not_found
    @teamship = @team.teamships.find_by(account: current_account)
    redirect(@teamship ? "/g/#{@gathering.slug}/teamships/#{@teamship.id}/unsubscribe" : "/g/#{@gathering.slug}/teams/#{@team.id}")
  end

  get '/g/:slug/teamships/:id/subscribe' do
    @gathering = gathering_from_params || not_found
    @teamship = @gathering.teamships.find(params[:id]) || not_found
    @team = @teamship.team
    confirmed_membership_required!
    own_or_gathering_admins_only!(@teamship)
    partial :'teams/subscribe', locals: { teamship: @teamship }
  end

  post '/g/:slug/teamships/:id/set_subscribe' do
    @gathering = gathering_from_params || not_found
    @teamship = @gathering.teamships.find(params[:id]) || not_found
    @team = @teamship.team
    confirmed_membership_required!
    own_or_gathering_admins_only!(@teamship)
    @teamship.set(unsubscribed: false)
    if request.xhr?
      200
    else
      (flash[:notice] = "You'll now receive email notifications of new posts in #{@team.name}"
       redirect('/accounts/subscriptions'))
    end
  end

  get '/g/:slug/teamships/:id/unsubscribe' do
    @gathering = gathering_from_params || not_found
    @teamship = @gathering.teamships.find(params[:id]) || not_found
    @team = @teamship.team
    confirmed_membership_required!
    own_or_gathering_admins_only!(@teamship)
    @teamship.set(unsubscribed: true)
    @team.subscriptions.and(account: current_account).destroy_all
    if request.xhr?
      200
    else
      (flash[:notice] = "OK! You won't receive emails about #{@team.name}"
       redirect('/accounts/subscriptions'))
    end
  end
end
