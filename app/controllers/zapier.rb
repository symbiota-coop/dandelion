Dandelion::App.controller do
  get '/z', provides: :json do
    sign_in_required!
    { account_id: current_account.id }.to_json
  end

  get '/z/event_orders', provides: :json do
    @event = Event.find(params[:event_id])
    event_admins_only!
    @event.orders.complete.map do |order|
      {
        name: order.account.name,
        created_at: order.created_at
      }
    end.to_json
  end
end
