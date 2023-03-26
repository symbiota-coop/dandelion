Dandelion::App.controller do
  get '/z', provides: :json do
    sign_in_required!
    {
      id: current_account.id.to_s,
      name: current_account.name,
      email: current_account.email
    }.to_json
  end

  get '/z/organisation_events', provides: :json do
    @organisation = Organisation.find_by(slug: params[:organisation_slug])
    @organisation.events_for_search.map do |event|
      {
        id: event.id.to_s,
        name: "#{event.name} (#{event.concise_when_details(nil)})"
      }
    end.to_json
  end

  get '/z/organisation_event_orders', provides: :json do
    @organisation = Organisation.find_by(slug: params[:organisation_slug])
    @event = @organisation.events.find(params[:event_id])
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
        value: order.value,
        currency: order.currency,
        opt_in_organisation: order.opt_in_organisation,
        opt_in_facilitator: order.opt_in_facilitator,
        hear_about: order.hear_about,
        answers: order.answers,
        created_at: order.created_at.iso8601
      }
    end.to_json
  end
end
