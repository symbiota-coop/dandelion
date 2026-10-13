Dandelion::App.controller do
  post '/events/:id/purchase', provides: :json do
    @event = Event.find(params[:id]) || not_found
    halt 403 unless can_purchase_event_tickets?
    OrderBuilder.new(**order_builder_args).call
  rescue OrderBuilder::Duplicate => e
    halt 409, { duplicate: true, error: e.message }.to_json
  rescue OrderBuilder::TicketTypeNotFound
    not_found
  rescue OrderBuilder::Error => e
    halt e.status
  end
end
