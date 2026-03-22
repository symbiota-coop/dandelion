class PaymentMethod
  @all = []

  class << self
    attr_accessor :all
  end

  attr_accessor :name, :label, :dotted, :visible, :condition, :org_condition, :logo, :url, :process, :partial

  def initialize(name, options = {})
    @name = name
    @label = options[:label] || name.capitalize
    @dotted = options.fetch(:dotted, true)
    @visible = options.fetch(:visible, false)
    @condition = options[:condition] || ->(_event) { true }
    @org_condition = options[:org_condition]
    @logo = options[:logo]
    @url = options[:url]
    @process = options[:process]
    @partial = options[:partial]
    @order_currency = options[:order_currency]
    self.class.all << self
  end

  def self.object(name)
    all.find { |pm| pm.name == name.to_s }
  end

  def available?(event)
    condition.call(event)
  end

  def button_label(event)
    label.respond_to?(:call) ? label.call(event) : label
  end

  def process_payment(order:, event:, account: nil, details_form: nil, ticket_form: nil)
    process.call(order: order, event: event, account: account, details_form: details_form, ticket_form: ticket_form)
  end

  # Currency stored on the order when this payment method is selected (e.g. EVM + USD → BREAD).
  def order_currency_for(event)
    @order_currency&.call(event) || event.currency
  end
end

PaymentMethod.new('rsvp',
                   label: ->(event) { event.rsvp_button_text || 'RSVP' },
                   dotted: false,
                   visible: true,
                   process: lambda { |order:, **|
                     order.payment_completed!
                     order.send_tickets
                     order.create_order_notification
                     { order_id: order.id.to_s }.to_json
                   })

PaymentMethod.new('stripe',
                   label: 'Pay',
                   dotted: false,
                   org_condition: ->(org) { org.stripe_connect_json || org.stripe_pk },
                   condition: ->(event) {
                     (event.organisation.stripe_connect_json || event.organisation.stripe_sk) &&
                       FIAT_CURRENCIES.include?(event.currency)
                   },
                   logo: 'stripe.png',
                   url: 'https://stripe.com/',
                   process: lambda { |order:, event:, account:, details_form:, ticket_form:|
                     Stripe.api_key = event.organisation.stripe_connect_json ? ENV['STRIPE_SK'] : event.organisation.stripe_sk
                     Stripe.api_version = ENV['STRIPE_API_VERSION']

                     cohost = ticket_form[:cohost] && Organisation.find_by(slug: ticket_form[:cohost])
                     event_image = event.image_source(cohost)&.image&.thumb('1920x1920')
                     organisationship = event.revenue_sharer_organisationship

                     stripe_session_hash = {
                       customer_email: account.email,
                       success_url: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{event.slug}?success=true&order_id=#{order.id}&utm_source=#{details_form[:utm_source]}&utm_medium=#{details_form[:utm_medium]}&utm_campaign=#{details_form[:utm_campaign]}"),
                       cancel_url: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{event.slug}?cancelled=true"),
                       metadata: order.metadata,
                       billing_address_collection: event.organisation.billing_address_collection? ? 'required' : nil,
                       line_items: [{
                         name: event.name,
                         description: order.description,
                         images: [event_image.try(:url)].compact,
                         amount: (order.total * 100).round,
                         currency: order.currency,
                         quantity: 1,
                         tax_rates: event.tax_rate_id || event.organisation.tax_rate_id ? [event.tax_rate_id || event.organisation.tax_rate_id] : nil
                       }]
                     }

                     payment_intent_data = { description: order.description, metadata: order.metadata }
                     application_fee_amount = nil
                     if organisationship
                       application_fee_amount = order.calculate_application_fee_amount
                       if event.direct_charges
                         payment_intent_data.merge!(application_fee_amount: (application_fee_amount * 100).round)
                       else
                         payment_intent_data.merge!(
                           application_fee_amount: (application_fee_amount * 100).round,
                           transfer_data: { destination: organisationship.stripe_user_id }
                         )
                       end
                     elsif event.donations_to_dandelion?
                       application_fee_amount = order.donation_revenue.cents.to_f / 100
                       payment_intent_data.merge!(application_fee_amount: (application_fee_amount * 100).round)
                     end
                     stripe_session_hash.merge!(payment_intent_data: payment_intent_data)

                     session = if organisationship && event.direct_charges
                                 Stripe::Checkout::Session.create(stripe_session_hash, { stripe_account: organisationship.stripe_user_id })
                               else
                                 Stripe::Checkout::Session.create(stripe_session_hash, event.organisation.stripe_connect_json ? { stripe_account: event.organisation.stripe_user_id } : {})
                               end

                     order.update_attributes!(
                       value: order.total.round(2),
                       session_id: session.id,
                       payment_intent: session.payment_intent,
                       application_fee_amount: application_fee_amount
                     )
                     order.tickets.each do |ticket|
                       ticket.update_attributes!(session_id: session.id, payment_intent: session.payment_intent)
                     end

                     { session_id: session.id }.to_json
                   })

PaymentMethod.new('gocardless',
                   label: 'Pay with GoCardless',
                   org_condition: ->(org) { org.gocardless_instant_bank_pay && org.gocardless_access_token },
                   condition: ->(event) {
                     event.organisation.gocardless_instant_bank_pay &&
                       event.organisation.gocardless_access_token &&
                       FIAT_CURRENCIES.include?(event.currency)
                   },
                   logo: 'gocardless.png',
                   url: 'https://gocardless.com/',
                   process: lambda { |order:, event:, **|
                     client = GoCardlessPro::Client.new(access_token: event.organisation.gocardless_access_token)
                     billing_request = client.billing_requests.create(
                       params: {
                         payment_request: {
                           description: order.description.truncate(200),
                           amount: (order.total * 100).round,
                           currency: order.currency
                         }
                       }
                     )

                     order.update_attributes!(
                       value: order.total.round(2),
                       gocardless_payment_request_id: billing_request.links.payment_request
                     )
                     order.tickets.each do |ticket|
                       ticket.update_attributes!(gocardless_payment_request_id: billing_request.links.payment_request)
                     end

                     billing_request_flow = client.billing_request_flows.create(
                       params: {
                         redirect_uri: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{event.slug}?success=true&order_id=#{order.id}"),
                         exit_uri: URI::DEFAULT_PARSER.escape("#{ENV['BASE_URI']}/e/#{event.slug}?cancelled=true"),
                         links: { billing_request: billing_request.id }
                       }
                     )

                     { gocardless_billing_request_flow: billing_request_flow }.to_json
                   })

PaymentMethod.new('opencollective',
                   label: 'Pay with Open Collective',
                   org_condition: ->(org) { org.oc_slug },
                   condition: ->(event) { event.oc_slug },
                   logo: 'opencollective.png',
                   url: 'https://opencollective.com/',
                   partial: 'purchase/pay_with_opencollective',
                   process: lambda { |order:, **|
                     oc_secret = "dandelion:#{Array.new(5) { [*'a'..'z', *'0'..'9'].sample }.join}"
                     order.update_attributes!(
                       value: order.total.round(2),
                       oc_secret: oc_secret
                     )
                     {
                       oc_secret: order.oc_secret,
                       currency: order.currency,
                       value: order.value,
                       order_id: order.id.to_s,
                       order_expiry: (order.created_at + 1.hour).to_datetime.strftime('%Q')
                     }.to_json
                   })

PaymentMethod.new('evm',
                   label: ->(event) {
                     event.currency.in?(%w[BREAD USD]) ? 'Pay with BREAD on Gnosis Chain' : "Pay with #{event.chain.try(:name)}"
                   },
                   org_condition: ->(org) { org.evm_address },
                   condition: ->(event) {
                     event.chain &&
                       event.organisation.evm_address &&
                       (EVM_CURRENCIES.include?(event.currency) || event.currency == 'USD')
                   },
                   order_currency: ->(event) { event.currency == 'USD' ? 'BREAD' : event.currency },
                   partial: 'purchase/pay_with_evm',
                   process: lambda { |order:, **|
                     evm_secret = Array.new(4) { [*'1'..'9'].sample }.join
                     order.update_attributes!(
                       value: order.total.round(2),
                       evm_secret: evm_secret
                     )
                     {
                       evm_secret: order.evm_secret,
                       evm_value: order.evm_value,
                       evm_wei: (order.evm_value * 1e18.to_d).to_i,
                       order_id: order.id.to_s,
                       order_expiry: (order.created_at + 1.hour).to_datetime.strftime('%Q')
                     }.to_json
                   })
