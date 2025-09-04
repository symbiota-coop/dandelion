Dandelion::App.controller do
  get '/point/:model/:id' do
    partial :"maps/#{params[:model].underscore}", object: params[:model].constantize.find(params[:id])
  end

  get '/map', provides: %i[html json] do
    @accounts = []
    @local_groups = []

    if params[:organisation_id]
      @organisation = Organisation.find(params[:organisation_id]) || not_found
      @enable_info_window = params[:admin] && organisation_admin?
      @accounts = Account.all
      @accounts = if params[:monthly_donors]
                    @accounts.and(:id.in => @organisation.organisationships.and(:hide_membership.ne => true, :monthly_donation_method.ne => nil).pluck(:account_id))
                  else
                    @accounts.and(organisation_ids_public_cache: @organisation.id)
                  end
    elsif params[:activity_id]
      @activity = Activity.find(params[:activity_id]) || not_found
      @enable_info_window = params[:admin] && activity_admin?
      @accounts = Account.and(:id.in => @activity.activityships.and(:hide_membership.ne => true).pluck(:account_id))
    elsif params[:local_group_id]
      @local_group = LocalGroup.find(params[:local_group_id]) || not_found
      @enable_info_window = params[:admin] && local_group_admin?
      @accounts = Account.and(:id.in => @local_group.local_groupships.and(:hide_membership.ne => true).pluck(:account_id))
      @local_groups = [@local_group]
    else
      @accounts = Account.all
    end

    case content_type
    when :html
      erb :'maps/map'
    when :json
      map_data_json(@accounts,
                    polygonables: @local_groups,
                    enable_info_window: @enable_info_window)
    end
  end

  get '/map/trigger' do
    200
  end
end
