Dandelion::App.controller do
  get '/z', provides: :json do
    sign_in_required!
    current_account.api_hash.to_json
  end

  get '/z/organisation_events', provides: :json do
    @organisation = Organisation.find_by(slug: params[:organisation_slug]) || not_found
    organisation_admins_only!
    @organisation.admin_events.map(&:admin_list_hash).to_json
  end

  get '/z/organisation_followers', provides: :json do
    @organisation = Organisation.find_by(slug: params[:organisation_slug]) || not_found
    organisation_admins_only!
    @organisation.recent_followers.map(&:api_hash).to_json
  end

  get '/z/organisation_event_orders', provides: :json do
    @organisation = Organisation.find_by(slug: params[:organisation_slug]) || not_found
    @event = @organisation.events_including_cohosted.find(params[:event_id]) || not_found
    event_admins_only!
    @event.orders.complete.includes(:account).order('created_at desc').map { |order| order.api_hash(current_account) }.to_json
  end
end
