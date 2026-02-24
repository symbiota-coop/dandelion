Dandelion::App.controller do
  get '/points/:model/:id' do
    decrypted = decrypt_map_id(params[:id])
    halt 400 unless decrypted
    halt 400 unless decrypted[:model_name] == params[:model]
    halt 400 unless %w[Account ActivityApplication Event Gathering Organisation Organisationship].include?(decrypted[:model_name])

    object = decrypted[:model_name].constantize.find(decrypted[:id])

    unless admin?
      halt 403 if decrypted[:model_name] == 'Account' && (object.location_privacy != 'Public')
      halt 403 if %w[ActivityApplication Organisationship].include?(decrypted[:model_name]) && (object.account.location_privacy != 'Public')
    end

    partial :"points/#{decrypted[:model_name].underscore}", object: object
  end

  get '/map', provides: %i[html json] do
    @accounts = []

    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id]) || not_found
      @accounts = Account.all
      @accounts = @accounts.and(organisation_ids_public_cache: @organisation.id)
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id]) || not_found
      @accounts = Account.and(:id.in => @activity.activityships.and(hide_membership: false).pluck(:account_id))
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id]) || not_found
      @accounts = Account.and(:id.in => @local_group.local_groupships.and(hide_membership: false).pluck(:account_id))
    else
      @accounts = Account.all
    end

    case content_type
    when :html
      erb :'maps/map'
    when :json
      map_json(@accounts)
    end
  end

  get '/map/trigger' do
    200
  end

  get '/map/home' do
    partial :'maps/map', locals: { url: '/events', fill_screen: true }
  end
end
