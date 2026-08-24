Dandelion::App.controller do
  get '/z', provides: :json do
    sign_in_required!
    current_account.api_hash.to_json
  end

  get '/z/organisation_events', provides: :json do
    @organisation = organisation_from_params || not_found
    organisation_admins_only!
    @organisation.admin_events.map(&:admin_list_hash).to_json
  end

  get '/z/organisation_followers', provides: :json do
    @organisation = organisation_from_params || not_found
    organisation_admins_only!
    @organisation.recent_followers.map(&:api_hash).to_json
  end

  get '/z/organisation_event_orders', provides: :json do
    @event = event_from_params || not_found
    event_admins_only!
    @event.admin_orders.map { |order| order.api_hash(current_account) }.to_json
  end

  get '/z/organisation_event_tickets', provides: :json do
    @event = event_from_params || not_found
    event_admins_only!
    @event.admin_tickets.map { |ticket| ticket.api_hash(current_account) }.to_json
  end
end
