Dandelion::App.helpers do
  def monthly_donor_for_event?(event = @event, account = current_account)
    account && event.organisation.organisationships.find_by(:account => account, :monthly_donation_method.ne => nil)
  end

  def activity_member_for_event?(event = @event, account = current_account)
    event.activity && account && event.activity.activityships.find_by(account: account)
  end

  def can_purchase_event_tickets?(event = @event, account = current_account)
    return false unless event
    return false if event.locked? && !event_admin?(event, account)
    return false if event.monthly_donors_only && !monthly_donor_for_event?(event, account)
    return false if event.activity && event.activity.privacy != 'open' && !activity_member_for_event?(event, account)

    true
  end

  def currency_input_row(label:, field_name:, field_id:, value: nil)
    input = number_field_tag field_name, value: value, id: field_id, class: 'form-control', style: 'width: 5em', disabled: true
    <<-HTML
      <tr>
        <td></td>
        <td></td>
        <td style="min-width: 8em">
          <strong>#{label}</strong>
          <div class="input-group my-1">
            <span class="input-group-text">#{money_symbol(@event.currency)}</span>
            #{input}
          </div>
        </td>
      </tr>
    HTML
  end

  def payment_button(method:, label:, condition:, outline: true, visible: false)
    return '' unless condition

    style = visible ? '' : 'display: none'
    btn_class = outline ? 'btn btn-outline-primary w-100 mb-1' : 'btn btn-primary w-100 mb-1'
    hidden_input = hidden_field_tag :payment_method, value: method, disabled: true
    label = ERB::Util.html_escape(label)
    method = ERB::Util.html_escape(method)
    <<-HTML
      <button style="#{style}" class="#{btn_class}" type="submit" data-payment-method="#{method}">
        <span>#{label}</span>
        <i class="bi bi-spin bi-slash-lg" style="display: none"></i>
      </button>
      #{hidden_input}
    HTML
  end

  # The checkout form's fields as OrderBuilder arguments. OrderBuilder handles
  # its own failures; this only covers a malformed form.
  def order_builder_args
    ticket_form = params[:ticketForm]
    details_form = params[:detailsForm]
    account_data = details_form[:account]

    {
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
    }
rescue StandardError => e
  ErrorReporting.capture_exception(e)
  halt 400
  end

end
