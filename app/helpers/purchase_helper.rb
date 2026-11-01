Dandelion::App.helpers do
  def can_purchase_event_tickets?(event = @event, account = current_account)
    event && !event.booking_restriction(account) { event_admin?(event, account) }
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
    # A checkbox sends '1', or ['0', '1'] when it follows a hidden field
    checked = ->(value) { Array(value).include?('1') }

    {
      event: @event,
      buyer: %i[name email phone postcode country].index_with { |field| account_data[field] },
      signed_in_account: current_account,
      new_account_currency: visitor_currency,
      secret_ticket_type_id: ticket_form[:ticket_type_id],
      payment_method: details_form[:payment_method],
      answers: question_answer_pairs(details_form),
      donation_via_modal: checked.(ticket_form[:donation_via_modal]),
      opt_in_organisation: checked.(account_data[:opt_in_organisation]),
      opt_in_facilitator: checked.(account_data[:opt_in_facilitator]),
      confirmed_duplicate: checked.(params[:confirmed_duplicate]),
      utm: %i[source medium campaign].index_with { |field| details_form[:"utm_#{field}"] }
    }.merge(
      %i[quantities prices donation_amount discount_code_id cohost affiliate_type affiliate_id].index_with { |field| ticket_form[field] },
      %i[hear_about via http_referrer].index_with { |field| account_data[field] }
    )
  rescue StandardError => e
    ErrorReporting.capture_exception(e)
    halt 400
  end
end
