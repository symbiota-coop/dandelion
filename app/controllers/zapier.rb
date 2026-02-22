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
    @organisation = Organisation.find_by(slug: params[:organisation_slug]) || not_found
    organisation_admins_only!
    @organisation.events_including_cohosted.without_heavy_fields.order('start_time desc').map do |event|
      {
        id: event.id.to_s,
        name: "#{event.name} (#{event.concise_when_details(nil)})"
      }
    end.to_json
  end

  get '/z/organisation_followers', provides: :json do
    @organisation = Organisation.find_by(slug: params[:organisation_slug]) || not_found
    organisation_admins_only!
    @organisation.organisationships.only(:account_id, :created_at).includes(:account).and(:created_at.gte => 1.day.ago).order('created_at desc').map do |organisationship|
      {
        id: organisationship.id.to_s,
        name: organisationship.account.name,
        firstname: organisationship.account.firstname,
        lastname: organisationship.account.lastname,
        email: organisationship.account.email,
        created_at: organisationship.created_at.iso8601
      }
    end.to_json
  end

  get '/z/organisation_event_orders', provides: :json do
    @organisation = Organisation.find_by(slug: params[:organisation_slug]) || not_found
    @event = @organisation.events_including_cohosted.find(params[:event_id]) || not_found
    event_admins_only!
    @event.orders.complete.includes(:account).order('created_at desc').map do |order|
      {
        id: order.id.to_s,
        name: order.account ? order.account.name : '',
        firstname: order.account ? order.account.firstname : '',
        lastname: order.account ? order.account.lastname : '',
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
        via: order.via,
        answers: order.answers,
        created_at: order.created_at.iso8601
      }
    end.to_json
  end
end
