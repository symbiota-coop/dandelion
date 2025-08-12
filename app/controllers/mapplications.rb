Dandelion::App.controller do
  get '/g/:slug/mapplications/:id' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @mapplication = @gathering.mapplications.find(params[:id]) || not_found
    if request.xhr?
      partial :'mapplications/mapplication_modal', locals: { mapplication: @mapplication }
    else
      erb :'mapplications/mapplication'
    end
  end

  get '/mapplication_row/:id' do
    @mapplication = Mapplication.find(params[:id]) || not_found
    @gathering = @mapplication.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    partial :'mapplications/mapplication_row', locals: { mapplication: @mapplication }
  end

  get '/g/:slug/apply' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    redirect '/' if @gathering.privacy == 'secret'
    redirect "/g/#{@gathering.slug}/join" if @gathering.privacy == 'open'
    @title = @gathering.name
    @og_desc = "#{@gathering.name} is being co-created on Dandelion"
    @og_image = @gathering.image.thumb('1920x1920').url if @gathering.image
    @account = Account.new
    erb :'mapplications/apply'
  end

  post '/g/:slug/apply' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found

    if current_account
      @account = current_account
    else

      if ENV['RECAPTCHA_SECRET_KEY']
        agent = Mechanize.new
        captcha_response = JSON.parse(agent.post(ENV['RECAPTCHA_VERIFY_URL'], { secret: ENV['RECAPTCHA_SECRET_KEY'], response: params['g-recaptcha-response'] }).body)
        unless captcha_response['success'] == true
          flash[:error] = "Our systems think you're a bot. Please try a different device or browser, or email #{ENV['CONTACT_EMAIL']} if you keep having trouble."
          redirect(back)
        end
      end

      redirect back unless params[:account] && params[:account][:email]
      unless (@account = Account.find_by(email: params[:account][:email].downcase))
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
      @mapplication = @gathering.mapplications.build account: @account, status: 'pending', answers: (params[:answers].map { |i, x| [@gathering.application_questions_a[i.to_i], x] } if params[:answers])
      if @mapplication.save
        if @mapplication.acceptable? && @mapplication.meets_threshold
          @mapplication.accept
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
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @mapplications = @gathering.mapplications.pending
    @mapplications = @mapplications.and(:account_id.in => Account.and(name: /#{Regexp.escape(params[:q])}/i).pluck(:id)) if params[:q]
    erb :'mapplications/pending'
  end

  get '/g/:slug/threshold' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    partial :'mapplications/threshold'
  end

  post '/g/:slug/threshold' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @membership.desired_threshold = params[:desired_threshold]
    @membership.save!
    200
  end

  get '/g/:slug/applications/paused' do
    @gathering = Gathering.find_by(slug: params[:slug]) || not_found
    @membership = @gathering.memberships.find_by(account: current_account)
    confirmed_membership_required!
    @mapplications = @gathering.mapplications.paused
    erb :'mapplications/paused'
  end

  post '/mapplications/:id/verdicts/create' do
    @mapplication = Mapplication.find(params[:id]) || not_found
    @gathering = @mapplication.gathering
    confirmed_membership_required!
    verdict = @mapplication.verdicts.build(params[:verdict])
    verdict.account = current_account
    verdict.save
    200
  end

  get '/verdicts/:id/destroy' do
    @verdict = Verdict.find(params[:id]) || not_found
    halt unless @verdict.account.id == current_account.id
    @verdict.destroy
    200
  end

  get '/mapplications/:id/process' do
    @mapplication = Mapplication.find(params[:id]) || not_found
    @gathering = @mapplication.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @mapplication.update_attribute(:processed_by, current_account)
    case params[:status]
    when 'accepted'
      @mapplication.accept if @mapplication.acceptable?
    when 'pending'
      @mapplication.update_attribute(:status, 'pending')
    when 'paused'
      @mapplication.update_attribute(:status, 'paused')
    end
    redirect back
  end

  get '/mapplications/:id/destroy' do
    @mapplication = Mapplication.find(params[:id]) || not_found
    @gathering = @mapplication.gathering
    @membership = @gathering.memberships.find_by(account: current_account)
    gathering_admins_only!
    @mapplication.destroy
    redirect back
  end
end
