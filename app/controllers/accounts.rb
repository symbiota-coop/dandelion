Dandelion::App.controller do
  get '/accounts', provides: [:json] do
    @accounts = Account.public
    @accounts = @accounts.and(:id.in => search_accounts(params[:q]).pluck(:id)) if params[:q]
    @accounts = @accounts.and(id: params[:id]) if params[:id]
    case content_type
    when :json
      {
        results: @accounts.map { |account| { id: account.id.to_s, text: "#{account.name} (#{account.username})" } }
      }.to_json
    end
  end

  get '/confirm_email' do
    sign_in_required!
    current_account.send_confirmation_email
    flash[:notice] = 'Please click the link in the email to confirm your email address.'
    redirect '/accounts/edit'
  end

  get '/confirm_email/:sign_in_token' do
    sign_in_required!
    current_account.set(email_confirmed: true)
    flash[:notice] = 'Your email address was confirmed.'
    redirect '/accounts/edit'
  end

  get '/accounts/sign_in' do
    @hide_right_nav = true
    erb :'accounts/sign_in'
  end

  post '/accounts/sign_in_code' do
    if params[:email] && (@account = Account.find_by(email: params[:email].downcase))
      @account.send_sign_in_code
      erb :'accounts/requested_sign_in_code'
    elsif params[:code]
      redirect "/?sign_in_token=#{params[:code].strip}"
    else
      flash[:error] = "There's no account registered under that email address."
      redirect '/accounts/sign_in'
    end
  end

  get '/accounts/sign_out' do
    session.clear
    redirect '/'
  end

  get '/accounts/unsubscribe' do
    sign_in_required!
    current_account.update_attribute(:unsubscribed, true)
    flash[:notice] = 'You were unsubscribed from all emails.'
    redirect '/accounts/subscriptions'
  end

  get '/accounts/new' do
    @account = Account.new
    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id])
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id])
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id])
    elsif params[:event_id]
      @event = Event.find(params[:event_id])
    end

    @hide_right_nav = true
    erb :'accounts/new'
  end

  post '/accounts/new' do
    @account = Account.new(mass_assigning(params[:account], Account))
    @account.password = Account.generate_password # not used
    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id])
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id])
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id])
    elsif params[:event_id]
      @event = Event.find(params[:event_id])
    end

    if params[:recaptcha_skip_secret] == ENV['RECAPTCHA_SKIP_SECRET']
      # continue
    elsif ENV['RECAPTCHA_SECRET_KEY']
      agent = Mechanize.new
      captcha_response = JSON.parse(agent.post('https://www.google.com/recaptcha/api/siteverify', { secret: ENV['RECAPTCHA_SECRET_KEY'], response: params['g-recaptcha-response'] }).body)
      unless captcha_response['success'] == true
        flash[:error] = "Our systems think you're a bot. Please email #{ENV['CONTACT_EMAIL']} if you keep having trouble."
        redirect(back)
      end
    end

    if session['omniauth.auth']
      @provider = Provider.object(session['omniauth.auth']['provider'])
      @account.provider_links.build(provider: @provider.display_name, provider_uid: session['omniauth.auth']['uid'], omniauth_hash: session['omniauth.auth'])
      # @account.picture_url = @provider.image.call(session['omniauth.auth']) unless @account.picture
    end

    if @account.save
      flash[:notice] = '<strong>Awesome!</strong> Your account was created successfully.'
      unless params[:recaptcha_skip_secret]
        @account.sign_ins.create(env: env_yaml)
        session[:account_id] = @account.id.to_s
      end
      if params[:list_an_event]
        redirect '/events/new'
      elsif params[:organisation_id]
        @organisation = Organisation.find(params[:organisation_id])
        organisationship = @organisation.organisationships.create account: @account, skip_welcome: params[:skip_welcome], referrer_id: params[:referrer_id]
        if organisationship.referrer
          redirect "/o/#{@organisation.slug}/via/#{organisationship.referrer.username}?registered=true"
        else
          redirect "/accounts/edit?organisation_id=#{@organisation.id}"
        end
      elsif params[:activity_id]
        @activity = Activity.find(params[:activity_id])
        @activity.organisation.organisationships.create account: @account
        @activity.activityships.create account: @account
        redirect "/accounts/edit?activity_id=#{@activity.id}"
      elsif params[:local_group_id]
        @local_group = LocalGroup.find(params[:local_group_id])
        @local_group.organisation.organisationships.create account: @account
        @local_group.local_groupships.create account: @account
        redirect "/accounts/edit?local_group_id=#{@local_group.id}"
      elsif params[:event_id]
        @event = Event.find(params[:event_id])
        @event.organisation.organisationships.create(account: @account)
        @event.activity.activityships.create(account: @account) if @event.activity
        @event.local_group.local_groupships.create(account: @account) if @event.local_group
        redirect "/accounts/edit?event_id=#{@event.id}"
      else
        redirect '/accounts/edit'
      end
    elsif @account.email && (account = Account.find_by(email: @account.email.downcase))
      if params[:organisation_id] || params[:activity_id] || params[:local_group_id] || params[:event_id]
        if params[:organisation_id]
          @organisation = Organisation.find(params[:organisation_id])
          @organisation.organisationships.create account: account, skip_welcome: params[:skip_welcome], referrer_id: params[:referrer_id]
        elsif params[:activity_id]
          @activity = Activity.find(params[:activity_id])
          @activity.organisation.organisationships.create account: @account
          @activity.activityships.create account: @account
        elsif params[:local_group_id]
          @local_group = LocalGroup.find(params[:local_group_id])
          @local_group.organisation.organisationships.create account: @account
          @local_group.local_groupships.create account: @account
        elsif params[:event_id]
          @event = Event.find(params[:event_id])
          @event.organisation.organisationships.create(account: @account)
          @event.activity.activityships.create(account: @account) if @event.activity
          @event.local_group.local_groupships.create(account: @account) if @event.local_group
        end
        if params[:recaptcha_skip_secret]
          200
        else
          flash[:notice] = "OK, you're on the list!"
          redirect(back)
        end
      else
        flash[:error] = "There's already an account registered under that email address. You can request a sign in code below."
        redirect '/accounts/sign_in'
      end
    elsif params[:recaptcha_skip_secret]
      400
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the account from being saved.'
      erb :'accounts/new'
    end
  end

  get '/accounts/edit' do
    sign_in_required!
    @account = current_account
    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id])
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id])
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id])
    elsif params[:event_id]
      @event = Event.find(params[:event_id])
    end
    erb :'accounts/edit'
  end

  get '/accounts/subscriptions' do
    sign_in_required!
    @account = current_account
    erb :'accounts/subscriptions'
  end

  get '/accounts/providers' do
    sign_in_required!
    @account = current_account
    erb :'accounts/providers'
  end

  get '/accounts/delete' do
    sign_in_required!
    @account = current_account
    erb :'accounts/delete'
  end

  post '/accounts/subscriptions' do
    sign_in_required!
    @account = current_account
    if @account.update_attributes(mass_assigning(params[:account], Account))
      flash[:notice] = 'Your preferences were saved.'
      redirect back
    else
      flash[:error] = '<strong>Oops.</strong> Some errors prevented the account from being saved.'
      redirect '/accounts/edit'
    end
  end

  post '/accounts/edit' do
    sign_in_required!
    @account = current_account
    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id])
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id])
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id])
    elsif params[:event_id]
      @event = Event.find(params[:event_id])
    end

    if @account.update_attributes(mass_assigning(params[:account], Account))
      flash[:notice] = '<strong>Awesome!</strong> Your account was updated successfully.'
      @account.notifications_as_notifiable.and(type: 'updated_profile').destroy_all
      @account.notifications_as_notifiable.create! circle: @account, type: 'updated_profile'
      redirect(if params[:slug]
                 "/g/#{params[:slug]}"
               elsif @organisation
                 "/o/#{@organisation.slug}"
               elsif @activity
                 "/activities/#{@activity.id}"
               elsif @local_group
                 "/local_groups/#{@local_group.id}"
               elsif @event
                 "/e/#{@event.slug}"
               elsif @account.sign_ins_count == 1
                 '/'
               else
                 '/accounts/edit'
               end)
    else
      flash.now[:error] = '<strong>Oops.</strong> Some errors prevented the account from being saved.'
      erb :'accounts/edit'
    end
  end

  get '/accounts/privacyable/:p' do
    sign_in_required!
    @account = current_account
    partial :'accounts/privacyable', locals: { p: params[:p] }
  end

  get '/accounts/set_privacyable/:p' do
    sign_in_required!
    @account = current_account
    halt 403 unless Account.privacyables.include?(params[:p])
    current_account.update_attribute("#{params[:p]}_privacy", params[:level])
    200
  end

  get '/accounts/unhide' do
    sign_in_required!
    current_account.update_attribute(:hidden, nil)
    current_account.update_attribute(:sign_ins_count, 1) if current_account.sign_ins_count.zero?
    redirect back
  end

  get '/accounts/:id' do
    @account = Account.find(params[:id]) || not_found
    redirect "/u/#{@account.username}"
  end

  post '/accounts/:id/reset_password', provides: :json do
    halt unless current_account && (current_account.admin? || current_account.can_reset_passwords?)
    @account = Account.find(params[:id]) || not_found
    @account.update_attribute(:password, Account.generate_password)
    @account.update_attribute(:failed_sign_in_attempts, nil)
    { password: @account.password }.to_json
  end

  get '/u/:username' do
    @account = Account.find_by(username: params[:username]) || not_found
    if request.xhr?
      if @account.private?
        partial :'accounts/private'
      else
        partial :'accounts/modal'
      end
    elsif @account.private? && (!current_account || (current_account.id != @account.id))
      flash[:error] = 'That profile is private' and redirect back
    else
      erb :'accounts/account'
    end
  end

  get '/accounts/:id/feedback_summary_email_preview' do
    account = Account.find(params[:id]) || not_found
    content = ERB.new(File.read(Padrino.root('app/views/emails/feedback_summary.erb'))).result(binding)
    Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css
  end

  get '/accounts/:id/following' do
    @account = Account.find(params[:id]) || not_found
    partial :'accounts/following', locals: { accounts: @account.following, starred: @account.following_starred }
  end

  get '/accounts/:id/organisations' do
    @account = Account.find(params[:id]) || not_found
    organisations = Organisation.and(:id.in => @account.organisationships.and(:hide_membership.ne => true).pluck(:organisation_id))
    partial :'organisations/blocks', locals: { organisations: organisations }
  end

  get '/accounts/:id/local_groups' do
    @account = Account.find(params[:id]) || not_found
    local_groups = LocalGroup.and(:id.in => @account.local_groupships.and(:hide_membership.ne => true).pluck(:local_group_id))
    partial :'local_groups/blocks', locals: { local_groups: local_groups }
  end

  get '/accounts/:id/activities' do
    @account = Account.find(params[:id]) || not_found
    activities = Activity.and(:id.in => @account.activityships.and(:hide_membership.ne => true).pluck(:activity_id))
    partial :'activities/blocks', locals: { activities: activities }
  end

  get '/accounts/:id/gatherings' do
    @account = Account.find(params[:id]) || not_found
    gatherings = Gathering.and(:id.in => @account.memberships.pluck(:gathering_id)).and(listed: true).and(:privacy.ne => 'secret')
    partial :'gatherings/blocks', locals: { gatherings: gatherings }
  end

  get '/accounts/:id/followers' do
    @account = Account.find(params[:id]) || not_found
    partial :'accounts/following', locals: { accounts: @account.followers }
  end

  get '/accounts/use_picture/:provider' do
    sign_in_required!
    @provider = Provider.object(params[:provider])
    @account = current_account
    @account.picture_url = @provider.image.call(@account.provider_links.find_by(provider: @provider.display_name).omniauth_hash)
    if @account.save
      flash[:notice] = "<i class=\"#{@provider.icon}\"></i> Grabbed your picture!"
      redirect '/accounts/edit'
    else
      flash.now[:error] = '<strong>Hmm.</strong> There was a problem grabbing your picture.'
      erb :'accounts/edit'
    end
  end

  get '/accounts/disconnect/:provider' do
    sign_in_required!
    @provider = Provider.object(params[:provider])
    @account = current_account
    if @account.provider_links.find_by(provider: @provider.display_name).destroy
      flash[:notice] = "<i class=\"#{@provider.icon}\"></i> Disconnected!"
      redirect '/accounts/providers'
    else
      flash.now[:error] = "<strong>Oops.</strong> The disconnect wasn't successful."
      erb :'accounts/edit'
    end
  end

  post '/accounts/update_location' do
    sign_in_required!
    @account = current_account
    @account.location = params[:location]
    @account.save
    redirect back
  end

  post '/accounts/destroy' do
    sign_in_required!
    if params[:email] && (params[:email] == current_account.email)
      flash[:notice] = 'Your account was deleted'
      current_account.destroy
      session.clear
      redirect '/'
    else
      flash[:error] = "The email you typed didn't match the email on this account"
      redirect back
    end
  end

  post '/accounts/:id/picture' do
    admins_only!
    @account = Account.find(params[:id]) || not_found
    @account.update_attribute(:picture, params[:picture])
    redirect back
  end

  get '/accounts/:id/show_feedback' do
    @account = Account.find(params[:id]) || not_found
    partial :'event_feedbacks/event_feedbacks', locals: { unscoped: true, event_feedbacks: @account.unscoped_event_feedbacks_as_facilitator }
  end

  # minimal

  get '/u/:username/feedback' do
    @account = Account.find_by(username: params[:username]) || not_found
    erb :'accounts/feedback', layout: (params[:minimal] ? 'minimal' : nil)
  end

  get '/accounts/:id/events' do
    @account = Account.find(params[:id]) || not_found
    events = Event.and(:id.in => EventFacilitation.and(:account_id.in => [@account.id] + @account.following_starred.pluck(:id)).pluck(:event_id)).live.public.future_and_current_featured
    partial :'events/blocks', locals: { events: events }, layout: 'minimal'
  end
end
