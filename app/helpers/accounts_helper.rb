Dandelion::App.helpers do
  def link_omniauth_provider(account)
    omniauth_data = request.env['omniauth.auth'] || session['omniauth.auth']
    return unless omniauth_data

    provider = Provider.object(omniauth_data['provider'])
    # atproto uses info.did instead of uid
    provider_uid = omniauth_data['uid'] || omniauth_data.dig('info', 'did')
    raise "Missing provider UID for #{provider.display_name}" unless provider_uid

    account.provider_links.build(
      provider: provider.display_name,
      provider_uid: provider_uid,
      omniauth_hash: omniauth_data
    )
  end

  def validate_recaptcha
    return unless ENV['RECAPTCHA_SECRET_KEY']

    agent = Mechanize.new
    captcha_response = JSON.parse(agent.post(ENV['RECAPTCHA_VERIFY_URL'], { secret: ENV['RECAPTCHA_SECRET_KEY'], response: params['g-recaptcha-response'] }).body)
    return if captcha_response['success'] == true

    flash[:error] = "Our systems think you're a bot. Please try a different device or browser, or email #{ENV['CONTACT_EMAIL']} if you keep having trouble."
    redirect(back)
  end

  def load_context
    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id])
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id])
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id])
    elsif params[:event_id]
      @event = Event.find(params[:event_id])
    end
  end

  def handle_successful_account_creation
    flash[:notice] = '<strong>Awesome!</strong> Your account was created successfully.'
    unless params[:recaptcha_skip_secret]
      @account.sign_ins.create(request: request)
      session[:account_id] = @account.id.to_s
    end

    if params[:list_an_event]
      redirect '/events/new'
    elsif params[:organisation_id]
      @organisation ||= Organisation.find(params[:organisation_id])
      organisationship = @account.associate_with_organisation!(@organisation, skip_welcome: params[:skip_welcome], referrer_id: params[:referrer_id])
      if organisationship&.referrer
        redirect "/o/#{@organisation.slug}/via/#{organisationship.referrer.username}?registered=true"
      else
        redirect "/accounts/edit?organisation_id=#{@organisation.id}"
      end
    elsif params[:activity_id] || params[:local_group_id] || params[:event_id]
      associate_account_with_context(@account)
      redirect_to_edit_or_referral
    else
      redirect '/accounts/edit'
    end
  end

  def handle_existing_account(existing_account)
    if params[:organisation_id] || params[:activity_id] || params[:local_group_id] || params[:event_id]
      associate_account_with_context(existing_account)
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
  end

  def associate_account_with_context(account)
    if params[:organisation_id]
      @organisation ||= Organisation.find(params[:organisation_id])
      account.associate_with_organisation!(@organisation, skip_welcome: params[:skip_welcome], referrer_id: params[:referrer_id])
    elsif params[:activity_id]
      @activity ||= Activity.find(params[:activity_id])
      account.associate_with_activity!(@activity)
    elsif params[:local_group_id]
      @local_group ||= LocalGroup.find(params[:local_group_id])
      account.associate_with_local_group!(@local_group)
    elsif params[:event_id]
      @event ||= Event.find(params[:event_id])
      account.associate_with_event!(@event)
    end
  end

  def redirect_to_edit_or_referral
    if params[:activity_id]
      redirect "/accounts/edit?activity_id=#{@activity.id}"
    elsif params[:local_group_id]
      redirect "/accounts/edit?local_group_id=#{@local_group.id}"
    elsif params[:event_id]
      redirect "/accounts/edit?event_id=#{@event.id}"
    end
  end
end
