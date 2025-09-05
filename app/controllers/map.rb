Dandelion::App.controller do
  get '/points/:model/:id' do
    halt 400 unless %w[Account ActivityApplication Event Gathering Organisation Organisationship].include?(params[:model])
    halt 400 if %w[Account ActivityApplication Organisationship].include?(params[:model]) && !admin?
    partial :"points/#{params[:model].underscore}", object: params[:model].constantize.find(params[:id])
  end

  get '/map', provides: %i[html json] do
    @accounts = []
    @local_groups = []

    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id]) || not_found
      @accounts = Account.all
      @accounts = @accounts.and(organisation_ids_public_cache: @organisation.id)
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id]) || not_found
      @accounts = Account.and(:id.in => @activity.activityships.and(:hide_membership.ne => true).pluck(:account_id))
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id]) || not_found
      @accounts = Account.and(:id.in => @local_group.local_groupships.and(:hide_membership.ne => true).pluck(:account_id))
      @local_groups = [@local_group]
    else
      @accounts = Account.all
    end

    case content_type
    when :html
      erb :'maps/map'
    when :json
      map_json(@accounts, polygonables: @local_groups)
    end
  end

  get '/map/trigger' do
    200
  end
end
