Dandelion::App.controller do
  get '/z', provides: :json do
    sign_in_required!
    { account_id: current_account.id.to_s }.to_json
  end

  get '/z/event_orders', provides: :json do
    @event = Event.find(params[:event_id])
    event_admins_only!
    @event.orders.complete.order('created_at desc').map do |order|
      {
        id: order.id.to_s,
        name: order.account ? order.account.name : '',
        email: if order_email_viewer?(order)
                 order.account ? order.account.email : ''
               else
                 ''
               end,
        value: m((order.value || 0), order.currency),
        created_at: order.created_at.to_s(:db)
      }
    end.to_json
  end
end
