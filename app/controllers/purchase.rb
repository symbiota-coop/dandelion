Dandelion::App.controller do
  post '/events/:id/purchase', provides: :json do
    @event = Event.find(params[:id]) || not_found
    halt 403 unless can_purchase_event_tickets?
    ticket_form = params[:ticketForm]
    details_form = params[:detailsForm]
    account_data = details_form[:account]

    OrderBuilder.new(
      event: @event,
      buyer: {
        name: account_data[:name],
        email: account_data[:email],
        phone: account_data[:phone],
        postcode: account_data[:postcode],
        country: account_data[:country]
      },
      signed_in_account: current_account,
      new_account_currency: visitor_currency,
      quantities: ticket_form[:quantities],
      prices: ticket_form[:prices],
      secret_ticket_type_id: ticket_form[:ticket_type_id],
      payment_method: details_form[:payment_method],
      answers: question_answer_pairs(details_form),
      donation_amount: ticket_form[:donation_amount],
      donation_via_modal: ticket_form[:donation_via_modal].to_s == '1',
      discount_code_id: ticket_form[:discount_code_id],
      cohost: ticket_form[:cohost],
      affiliate_type: ticket_form[:affiliate_type],
      affiliate_id: ticket_form[:affiliate_id],
      opt_in_organisation: account_data[:opt_in_organisation] == '1' || (account_data[:opt_in_organisation].is_a?(Array) && account_data[:opt_in_organisation].include?('1')),
      opt_in_facilitator: account_data[:opt_in_facilitator].is_a?(Array) && account_data[:opt_in_facilitator].include?('1'),
      hear_about: account_data[:hear_about],
      via: account_data[:via],
      http_referrer: account_data[:http_referrer],
      confirmed_duplicate: params[:confirmed_duplicate] == '1',
      utm: { source: details_form[:utm_source], medium: details_form[:utm_medium], campaign: details_form[:utm_campaign] }
    ).call
  rescue OrderBuilder::Duplicate => e
    halt 409, { duplicate: true, error: e.message }.to_json
  rescue OrderBuilder::TicketTypeNotFound
    not_found
  rescue OrderBuilder::Error => e
    halt e.status
  rescue StandardError => e
    ErrorReporting.capture_exception(e)
    halt 400
  end
end
