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
    input = number_field_tag field_name, value: value, id: field_id, class: 'form-control', disabled: true
    <<-HTML
      <tr>
        <td></td>
        <td></td>
        <td style="min-width: 8em">
          <strong>#{label}</strong>
          <div class="input-group" style="margin: 5px 0">
            <div class="input-group-prepend">
              <span class="input-group-text">#{money_symbol(@event.currency)}</span>
            </div>
            #{input}
          </div>
        </td>
      </tr>
    HTML
  end

  def payment_button(method:, label:, condition:, outline: true, visible: false)
    return '' unless condition

    style = visible ? '' : 'display: none'
    btn_class = outline ? 'btn btn-outline-primary btn-block mb-1' : 'btn btn-primary btn-block mb-1'
    hidden_input = hidden_field_tag :payment_method, value: method, disabled: true
    <<-HTML
      <button style="#{style}" class="#{btn_class}" type="submit" data-payment-method="#{method}">
        <span>#{label}</span>
        <i class="bi bi-spin bi-slash-lg" style="display: none"></i>
      </button>
      #{hidden_input}
    HTML
  end

  def ignore_dandelion_donation?(details_form)
    @event.donations_to_dandelion? && details_form[:payment_method].to_s != 'stripe'
  end

end
