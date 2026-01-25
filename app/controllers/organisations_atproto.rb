Dandelion::App.controller do
  get '/o/:slug/atproto/connect' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    erb :'organisations/atproto_connect'
  end

  post '/o/:slug/atproto/connect' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!

    @organisation.atproto_handle = params[:atproto_handle]&.strip&.delete_prefix('@')
    @organisation.atproto_app_password = params[:atproto_app_password]&.strip

    if @organisation.verify_and_set_atproto_credentials!
      flash[:notice] = 'Connected to Bluesky/ATProto!'
      redirect "/o/#{@organisation.slug}/atproto/connect"
    else
      @organisation.atproto_handle = nil
      @organisation.atproto_app_password = nil
      flash.now[:error] = 'Invalid Bluesky/ATProto credentials. Please check your handle and app password.'
      erb :'organisations/atproto_connect'
    end
  end

  get '/o/:slug/atproto/disconnect' do
    @organisation = Organisation.find_by(slug: params[:slug]) || not_found
    organisation_admins_only!
    @organisation.disconnect_atproto!
    flash[:notice] = 'Disconnected from Bluesky/ATProto'
    redirect "/o/#{@organisation.slug}/atproto/connect"
  end
end
