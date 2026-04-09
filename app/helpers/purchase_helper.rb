Dandelion::App.helpers do
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

  def payment_button(method:, label:, condition:, dotted: true, visible: false)
    return '' unless condition

    style = visible ? '' : 'display: none'
    btn_class = 'btn btn-primary btn-block mb-1'
    btn_class += ' btn-dotted' if dotted
    hidden_input = hidden_field_tag :payment_method, value: method, disabled: true
    <<-HTML
      <button style="#{style}" class="#{btn_class}" type="submit" data-payment-method="#{method}">
        <span>#{label}</span>
        <i class="bi bi-spin bi-slash-lg" style="display: none"></i>
      </button>
      #{hidden_input}
    HTML
  end

  def find_or_create_account_for_purchase(details_form)
    account_hash = {
      name: details_form[:account][:name],
      email: details_form[:account][:email],
      phone: details_form[:account][:phone],
      postcode: details_form[:account][:postcode],
      country: details_form[:account][:country]
    }

    account = Account.find_by(email: details_form[:account][:email].downcase)
    account ||= Account.new(account_hash.merge(skip_confirmation_email: true))

    if account.persisted?
      account.update_attributes!(account_hash.map { |k, v| [k, v] if v }.compact.to_h)
    else
      begin
        account.save!
      rescue StandardError
        halt 400
      end
    end

    account
  end

  def create_order_with_tickets(ticket_form, details_form)
    order = Order.create!(
      build_order_attributes(ticket_form, details_form)
    )

    ticket_form[:quantities].each do |ticket_type_id, quantity|
      ticket_type = @event.ticket_types.find(ticket_type_id) || not_found
      quantity.to_i.times do
        order.tickets.create!(
          event: @event,
          account: @account,
          ticket_type: ticket_type,
          price: (ticket_form[:prices][ticket_type_id] if ticket_type.range || !ticket_type.price)
        )
      end
    end
    raise Order::NoTickets if order.tickets.empty?

    order.donations.create!(event: @event, account: @account, amount: ticket_form[:donation_amount]) if ticket_form[:donation_amount].to_f > 0

    order.filter_discounts if order.discount_code && order.discount_code.filter
    order.apply_credit if current_account
    order.apply_fixed_discount
    order.set(original_description: order.description)

    order
  end

  def build_order_attributes(ticket_form, details_form)
    account_data = details_form[:account]
    ticket_attrs = %i[cohost affiliate_type affiliate_id discount_code_id]
    account_attrs = %i[hear_about via gc_plan_id gc_given_name gc_family_name gc_address_line1 gc_city gc_postal_code gc_branch_code gc_account_number http_referrer]

    attributes = {
      event: @event,
      account: @account,
      currency: EventPaymentMethod.object(details_form[:payment_method])&.order_currency_for(@event) || @event.currency,
      organisation_revenue_share: @event.organisation_revenue_share,
      revenue_sharer: (@event.revenue_sharer_organisationship.account if @event.revenue_sharer_organisationship),
      opt_in_organisation: account_data[:opt_in_organisation] == '1' || (account_data[:opt_in_organisation].is_a?(Array) && account_data[:opt_in_organisation].include?('1')),
      opt_in_facilitator: account_data[:opt_in_facilitator].is_a?(Array) && account_data[:opt_in_facilitator].include?('1'),
      answers: question_answer_pairs(details_form),
      application_fee_paid_to_dandelion: !@event.revenue_sharer_organisationship && @event.donations_to_dandelion?,
      donation_via_modal: ticket_form[:donation_via_modal].to_s == '1'
    }

    ticket_attrs.each { |attr| attributes[attr] = ticket_form[attr] }
    account_attrs.each { |attr| attributes[attr] = account_data[attr] }

    attributes
  end

end
