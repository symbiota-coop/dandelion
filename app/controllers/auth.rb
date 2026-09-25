Dandelion::App.controller do
  get '/atproto/oauth-client-metadata.json', provides: :json do
    content_type 'application/json'
    AtprotoKeyManager.client_metadata.to_json
  end

  get '/auth/failure' do
    @body_class = 'gradient'
    flash.now[:error] = '<strong>Hmm.</strong> There was a problem signing you in.'
    erb :'accounts/sign_in'
  end

  %w[get post].each do |method|
    send(method, '/auth/:provider/callback') do
      if env['omniauth.auth']['provider'] == 'atproto'
        redirect '/auth/failure' unless AtprotoSetup.token_did_matches?(session, env['omniauth.auth'])
      end
      account = if env['omniauth.auth']['provider'] == 'account'
                  Account.find(env['omniauth.auth']['uid'])
                else
                  env['omniauth.auth'].delete('extra')
                  @provider = Provider.object(env['omniauth.auth']['provider'])
                  # atproto uses info.did instead of uid
                  provider_uid = env['omniauth.auth']['uid'] || env['omniauth.auth'].dig('info', 'did')
                  # Resolve handle, avatar, and display name for atproto
                  begin
                    if env['omniauth.auth']['provider'] == 'atproto' && provider_uid && (profile = AtprotoClient.new.get_profile(provider_uid))
                      env['omniauth.auth']['info']['handle'] = profile['handle']
                      env['omniauth.auth']['info']['avatar'] = profile['avatar']
                      env['omniauth.auth']['info']['name'] = profile['displayName']
                    end
                  rescue StandardError
                    nil
                  end
                  ProviderLink.find_for(@provider.display_name, provider_uid).try(:account)
                end
      if current_account && env['omniauth.auth']['provider'] != 'account' # already signed in; ask before connecting
        if account # someone's already connected
          flash[:error] = "Someone's already connected to that account!"
          redirect '/accounts/providers'
        end
        # The OAuth flow can be started by a cross-site GET, so linking waits for a same-origin POST
        session['omniauth.connect'] = env['omniauth.auth']
        @account = current_account
        @nickname = @provider.nickname.call(env['omniauth.auth'])
        erb :'accounts/confirm_provider'
      elsif account # not signed in
        account.sign_ins.create(request: request)
        session[:account_id] = account.id.to_s
        flash[:notice] = 'Signed in!'
        redirect session.delete(:return_to) || '/'
      else
        flash.now[:notice] = "<i class=\"#{@provider.icon}\"></i> That #{@provider.display_name} #{@provider.display_name == 'Ethereum' ? 'address' : 'account'} isn't yet connected to a Dandelion account. Let's create a new Dandelion account for you!"
        session['omniauth.auth'] = env['omniauth.auth']
        @account = Account.new
        @account.name = env['omniauth.auth']['info']['name']
        @account.email = env['omniauth.auth']['info']['email']
        # @account.image_url = @provider.image.call(env['omniauth.auth'])
        link_omniauth_provider(@account)
        erb :'accounts/new'
      end
    end
  end

  post '/accounts/providers/confirm' do
    sign_in_required!
    omniauth_data = session.delete('omniauth.connect') || redirect('/accounts/providers')
    @provider = Provider.object(omniauth_data['provider']) || redirect('/accounts/providers')
    provider_uid = omniauth_data['uid'] || omniauth_data.dig('info', 'did')
    if ProviderLink.find_for(@provider.display_name, provider_uid)
      flash[:error] = "Someone's already connected to that account!"
    else
      link_omniauth_provider(current_account, omniauth_data)
      if current_account.save
        flash[:notice] = "<i class=\"#{@provider.icon}\"></i> Connected!"
      else
        flash[:error] = 'There was an error connecting the account'
      end
    end
    redirect '/accounts/providers'
  end

  post '/accounts/providers/cancel' do
    session.delete('omniauth.connect')
    redirect '/accounts/providers'
  end
end
