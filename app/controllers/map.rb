Dandelion::App.controller do
  get '/points/:model/:id' do
    halt 400 unless %w[Account ActivityApplication Event Gathering Organisation Organisationship].include?(params[:model])

    object = params[:model].constantize.find(params[:id])

    unless admin?
      halt 403 if %w[Account].include?(params[:model]) && (object.location_privacy != 'Public')
      halt 403 if %w[ActivityApplication Organisationship].include?(params[:model]) && (object.account.location_privacy != 'Public')
    end

    partial :"points/#{params[:model].underscore}", object: object
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
end
