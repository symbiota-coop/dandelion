Dandelion::App.controller do
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
                  ProviderLink.find_by(provider: @provider.display_name, provider_uid: env['omniauth.auth']['uid']).try(:account)
                end
      if current_account # already signed in; attempt to connect
        if account # someone's already connected
          flash[:error] = "Someone's already connected to that account!"
        else # connect; Account never reaches here
          current_account.provider_links.build(provider: @provider.display_name, provider_uid: env['omniauth.auth']['uid'], omniauth_hash: env['omniauth.auth'])
          # current_account.picture_url = @provider.image.call(env['omniauth.auth']) unless current_account.picture
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
        if session[:return_to]
          redirect session[:return_to]
        else
          redirect '/'
        end
      else
        flash.now[:notice] = "<i class=\"#{@provider.icon}\"></i> There's no account connected to that address. Let's create one for you!"
        session['omniauth.auth'] = env['omniauth.auth']
        @account = Account.new
        @account.name = env['omniauth.auth']['info']['name']
        @account.email = env['omniauth.auth']['info']['email']
        # @account.picture_url = @provider.image.call(env['omniauth.auth'])
        @account.provider_links.build(provider: @provider.display_name, provider_uid: env['omniauth.auth']['uid'], omniauth_hash: env['omniauth.auth'])
        erb :'accounts/new'
      end
    end
  end
end
