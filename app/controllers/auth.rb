Dandelion::App.controller do
  get '/oauth-client-metadata.json', provides: :json do
    content_type 'application/json'
    AtprotoKeyManager.client_metadata.to_json
  end

  get '/auth/failure' do
    flash.now[:error] = '<strong>Hmm.</strong> There was a problem signing you in.'
    erb :'accounts/sign_in'
  end

  %w[get post].each do |method|
    send(method, '/auth/:provider/callback') do
      account = if env['omniauth.auth']['provider'] == 'account'
                  Account.find(env['omniauth.auth']['uid'])
                else
                  env['omniauth.auth'].delete('extra')
                  @provider = Provider.object(env['omniauth.auth']['provider'])
                  # atproto uses info.did instead of uid
                  provider_uid = env['omniauth.auth']['uid'] || env['omniauth.auth'].dig('info', 'did')
                  # Resolve handle, avatar, and display name for atproto
                  if env['omniauth.auth']['provider'] == 'atproto' && provider_uid && (profile = AtprotoClient.new.get_profile(provider_uid))
                    env['omniauth.auth']['info']['handle'] = profile['handle']
                    env['omniauth.auth']['info']['avatar'] = profile['avatar']
                    env['omniauth.auth']['info']['name'] = profile['displayName']
                  end
                  provider_uid ? ProviderLink.find_by(provider: @provider.display_name, provider_uid: provider_uid).try(:account) : nil
                end
      if current_account && env['omniauth.auth']['provider'] != 'account' # already signed in; attempt to connect
        if account # someone's already connected
          flash[:error] = "Someone's already connected to that account!"
        else # connect; Account never reaches here
          link_omniauth_provider(current_account)
          # current_account.image_url = @provider.image.call(env['omniauth.auth']) unless current_account.image
          if current_account.save
            flash[:notice] = "<i class=\"#{@provider.icon}\"></i> Connected!"
          else
            flash[:error] = 'There was an error connecting the account'
          end
        end
        redirect '/accounts/providers'
      elsif account # not signed in
        account.sign_ins.create(env: env_yaml)
        session[:account_id] = account.id.to_s
        flash[:notice] = 'Signed in!'
        redirect session[:return_to] || '/'
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
end
