Dandelion::App.controller do
  get '/g/:slug/mapplications/:id' do
    @gathering = gathering_from_params
    confirmed_membership_required!
    @mapplication = @gathering.mapplications.find(params[:id]) || not_found
    if request.xhr?
      partial :'mapplications/mapplication_modal', locals: { mapplication: @mapplication }
    else
      erb :'mapplications/mapplication'
    end
  end

  get '/g/:slug/mapplication_row/:id' do
    @gathering = gathering_from_params
    @mapplication = @gathering.mapplications.find(params[:id]) || not_found
    confirmed_membership_required!
    partial :'mapplications/mapplication_row', locals: { mapplication: @mapplication }
  end

  get '/g/:slug/apply' do # rubocop:disable Dandelion/GatheringPermission -- applying is for people who aren't members yet
    @gathering = gathering_from_params
    @membership = @gathering.memberships.find_by(account: current_account)
    redirect '/' if @gathering.privacy == 'secret'
    redirect "/g/#{@gathering.slug}/join" if @gathering.privacy == 'open'
    @title = @gathering.name
    @og_desc = "#{@gathering.name} is being co-created on Dandelion"
    @og_image = @gathering.image.encode('jpg', '-quality 90').thumb('1200x630').url if @gathering.image
    @account = Account.new
    erb :'mapplications/apply'
  end

  post '/g/:slug/apply' do
    @gathering = gathering_from_params
    halt 403 if @gathering.privacy == 'secret'

    if current_account
      @account = current_account
    else

      validate_recaptcha

      redirect back unless params[:account] && params[:account][:email]
      if (@account = Account.find_by(email: params[:account][:email].downcase.strip))
        submitted_signed_out = true
      else
        @account = Account.new(mass_assigning(params[:account], Account))
        @account.password = Account.generate_password # not used
        unless @account.save
          flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the account from being saved.'
          halt 400, erb(:'mapplications/apply')
        end
      end
    end

    if @gathering.memberships.find_by(account: @account)
      flash[:notice] = "You're already part of that gathering"
      redirect back
    elsif @gathering.mapplications.find_by(account: @account)
      flash[:notice] = "You've already applied to that gathering"
      redirect back
    else
      @mapplication = @gathering.mapplications.build account: @account, status: 'pending', answers: question_answer_pairs(params), submitted_signed_out: submitted_signed_out
      if @mapplication.save
        if @mapplication.acceptable? && @mapplication.meets_threshold && @mapplication.accept
          redirect(@gathering.redirect_on_acceptance || "/g/#{@gathering.slug}/apply?accepted=true")
        else
          redirect "/g/#{@gathering.slug}/apply?applied=true"
        end
      else
        flash.now[:error] = 'There was a problem saving the application'
        halt 400, erb(:'mapplications/apply')
      end
    end
  end

  get '/g/:slug/applications' do
    @gathering = gathering_from_params
    confirmed_membership_required!
    @mapplications = @gathering.mapplications.pending
    @mapplications = @mapplications.and(:account_id.in => Account.search(params[:q], child_scope: @mapplications, regex_search: true).pluck(:id)) if params[:q]
    erb :'mapplications/pending'
  end

  get '/g/:slug/threshold' do
    @gathering = gathering_from_params
    confirmed_membership_required!
    partial :'mapplications/threshold'
  end

  post '/g/:slug/threshold' do
    @gathering = gathering_from_params
    confirmed_membership_required!
    @membership.desired_threshold = params[:desired_threshold]
    @membership.save!
    200
  end

  get '/g/:slug/applications/paused' do
    @gathering = gathering_from_params
    confirmed_membership_required!
    @mapplications = @gathering.mapplications.paused
    erb :'mapplications/paused'
  end

  post '/g/:slug/mapplications/:id/verdicts/create' do
    @gathering = gathering_from_params
    @mapplication = @gathering.mapplications.find(params[:id]) || not_found
    confirmed_membership_required!
    verdict = @mapplication.verdicts.build(mass_assigning(params[:verdict], Verdict))
    verdict.account = current_account
    verdict.save
    200
  end

  post '/g/:slug/verdicts/:id/destroy' do
    @gathering = gathering_from_params
    @verdict = @gathering.verdicts.find(params[:id]) || not_found
    halt 403 unless current_account && @verdict.account_id == current_account.id
    @verdict.destroy
    200
  end

  post '/g/:slug/mapplications/:id/process' do
    @gathering = gathering_from_params
    @mapplication = @gathering.mapplications.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @mapplication.set(processed_by_id: current_account.id)
    case params[:status]
    when 'accepted'
      @mapplication.accept if @mapplication.acceptable?
    when 'pending'
      @mapplication.set(status: 'pending')
    when 'paused'
      @mapplication.set(status: 'paused')
    end
    redirect back
  end

  post '/g/:slug/mapplications/:id/destroy' do
    @gathering = gathering_from_params
    @mapplication = @gathering.mapplications.find(params[:id]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @mapplication.destroy
    redirect back
  end
end
