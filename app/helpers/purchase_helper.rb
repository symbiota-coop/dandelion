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
      currency: (details_form[:payment_method] == 'evm' && @event.currency == 'USD' ? 'BREAD' : @event.currency),
      organisation_revenue_share: @event.organisation_revenue_share,
      revenue_sharer: (@event.revenue_sharer_organisationship.account if @event.revenue_sharer_organisationship),
      opt_in_organisation: account_data[:opt_in_organisation] == '1' || (account_data[:opt_in_organisation].is_a?(Array) && account_data[:opt_in_organisation].include?('1')),
      opt_in_facilitator: account_data[:opt_in_facilitator].is_a?(Array) && account_data[:opt_in_facilitator].include?('1'),
      answers: (details_form[:answers].map { |i, x| [details_form[:questions][i], ((x.is_a?(Hash) ? x.values : x) unless x == 'false')] } if details_form[:answers] && details_form[:questions]),
      application_fee_paid_to_dandelion: !@event.revenue_sharer_organisationship && @event.donations_to_dandelion?
    }

    ticket_attrs.each { |attr| attributes[attr] = ticket_form[attr] }
    account_attrs.each { |attr| attributes[attr] = account_data[attr] }

    attributes
  end

  def process_payment(details_form, ticket_form)
    if @order.total > 0
      payment_method = details_form[:payment_method]
      case payment_method
      when 'stripe'
        process_stripe_payment(details_form, ticket_form)
      when 'coinbase'
        process_coinbase_payment
      when 'gocardless'
        process_gocardless_payment
      when 'opencollective'
        process_opencollective_payment
      when 'evm'
        process_evm_payment
      else
        raise Order::PaymentMethodNotFound
      end
    else
      process_free_order
    end
  end

  def process_stripe_payment(details_form, ticket_form)
    Stripe.api_key = @event.organisation.stripe_connect_json ? ENV['STRIPE_SK'] : @event.organisation.stripe_sk
    Stripe.api_version = '2020-08-27'

    event_image = get_event_image(ticket_form)
    stripe_session_hash = build_stripe_session_hash(details_form, event_image)
    payment_intent_data, application_fee_amount = build_payment_intent_data
    stripe_session_hash.merge!(payment_intent_data: payment_intent_data)

    session = create_stripe_session(stripe_session_hash)
    update_order_with_stripe_session(session, application_fee_amount)

    { session_id: session.id }.to_json
  end

  def get_event_image(ticket_form)
    cohost = ticket_form[:cohost] && Organisation.find_by(slug: ticket_form[:cohost])
    image_source = @event.image_source(cohost)
    image_source&.image&.thumb('1920x1920')
  end

  def build_stripe_session_hash(details_form, event_image)
    {
      customer_email: @account.email,
      success_url: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{@event.slug}?success=true&order_id=#{@order.id}&utm_source=#{details_form[:utm_source]}&utm_medium=#{details_form[:utm_medium]}&utm_campaign=#{details_form[:utm_campaign]}"),
      cancel_url: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{@event.slug}?cancelled=true"),
      metadata: @order.metadata,
      billing_address_collection: @event.organisation.billing_address_collection? ? 'required' : nil,
      line_items: [{
        name: @event.name,
        description: @order.description,
        images: [event_image.try(:url)].compact,
        amount: (@order.total * 100).round,
        currency: @order.currency,
        quantity: 1,
        tax_rates: @event.tax_rate_id || @event.organisation.tax_rate_id ? [@event.tax_rate_id || @event.organisation.tax_rate_id] : nil
      }]
    }
  end

  def build_payment_intent_data
    payment_intent_data = {
      description: @order.description,
      metadata: @order.metadata
    }

    application_fee_amount = nil
    if (organisationship = @event.revenue_sharer_organisationship)
      application_fee_amount = @order.calculate_application_fee_amount
      if @event.direct_charges
        payment_intent_data.merge!(application_fee_amount: (application_fee_amount * 100).round)
      else
        payment_intent_data.merge!(
          application_fee_amount: (application_fee_amount * 100).round,
          transfer_data: { destination: organisationship.stripe_user_id }
        )
      end
    elsif @event.donations_to_dandelion?
      application_fee_amount = @order.donation_revenue.cents.to_f / 100
      payment_intent_data.merge!(application_fee_amount: (application_fee_amount * 100).round)
    end

    [payment_intent_data, application_fee_amount]
  end

  def create_stripe_session(stripe_session_hash)
    organisationship = @event.revenue_sharer_organisationship
    if organisationship && @event.direct_charges
      Stripe::Checkout::Session.create(stripe_session_hash, { stripe_account: organisationship.stripe_user_id })
    else
      Stripe::Checkout::Session.create(stripe_session_hash, @event.organisation.stripe_connect_json ? { stripe_account: @event.organisation.stripe_user_id } : {})
    end
  end

  def update_order_with_stripe_session(session, application_fee_amount)
    @order.update_attributes!(
      value: @order.total.round(2),
      session_id: session.id,
      payment_intent: session.payment_intent,
      application_fee_amount: application_fee_amount
    )
    @order.tickets.each do |ticket|
      ticket.update_attributes!(
        session_id: session.id,
        payment_intent: session.payment_intent
      )
    end
  end

  def process_coinbase_payment
    client = CoinbaseCommerceClient::Client.new(api_key: @event.organisation.coinbase_api_key)
    checkout = client.checkout.create(
      name: @event.name,
      description: @order.description.truncate(200),
      pricing_type: 'fixed_price',
      local_price: {
        amount: @order.total,
        currency: @order.currency
      },
      requested_info: %w[email]
    )
    @order.update_attributes!(
      value: @order.total.round(2),
      coinbase_checkout_id: checkout.id
    )
    { checkout_id: checkout.id }.to_json
  end

  def process_gocardless_payment
    client = GoCardlessPro::Client.new(access_token: @event.organisation.gocardless_access_token)
    billing_request = client.billing_requests.create(
      params: {
        payment_request: {
          description: @order.description.truncate(200),
          amount: (@order.total * 100).round,
          currency: @order.currency
        }
      }
    )

    @order.update_attributes!(
      value: @order.total.round(2),
      gocardless_billing_request_id: billing_request.id
    )

    billing_request_flow = client.billing_request_flows.create(
      params: {
        redirect_uri: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{@event.slug}?success=true&order_id=#{@order.id}"),
        exit_uri: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{@event.slug}?cancelled=true"),
        links: {
          billing_request: billing_request.id
        }
      }
    )

    { gocardless_billing_request_flow: billing_request_flow }.to_json
  end

  def process_opencollective_payment
    oc_secret = "dandelion:#{Array.new(5) { [*'a'..'z', *'0'..'9'].sample }.join}"
    @order.update_attributes!(
      value: @order.total.round(2),
      oc_secret: oc_secret
    )
    {
      oc_secret: @order.oc_secret,
      currency: @order.currency,
      value: @order.value,
      order_id: @order.id.to_s,
      order_expiry: (@order.created_at + 1.hour).to_datetime.strftime('%Q')
    }.to_json
  end

  def process_evm_payment
    evm_secret = Array.new(4) { [*'1'..'9'].sample }.join
    @order.update_attributes!(
      value: @order.total.round(2),
      evm_secret: evm_secret
    )
    {
      evm_secret: @order.evm_secret,
      evm_value: @order.evm_value,
      evm_wei: (@order.evm_value * 1e18.to_d).to_i,
      order_id: @order.id.to_s,
      order_expiry: (@order.created_at + 1.hour).to_datetime.strftime('%Q')
    }.to_json
  end

  def process_free_order
    @order.payment_completed!
    @order.send_tickets
    @order.create_order_notification
    { order_id: @order.id.to_s }.to_json
  end
end
