class EventPaymentMethod
  @all = []

  class << self
    attr_accessor :all
  end

  attr_accessor :name, :label, :outline, :visible, :event_condition, :org_condition, :process, :partial,
                :provider_name, :badge_class, :badge_background, :badge_color, :badge_text, :identity_fields,
                :payment_id_field, :refund, :purchase_errors, :card, :complimentary, :platform_donations,
                :dashboard_help

  def initialize(name, options = {})
    @name = name
    @label = options[:label] || name.capitalize
    @outline = options.fetch(:outline, true)
    @visible = options.fetch(:visible, false)
    @event_condition = options[:event_condition] || ->(_event) { true }
    @org_condition = options[:org_condition]
    @process = options[:process]
    @partial = options[:partial]
    @order_currency = options[:order_currency]
    @provider_name = options[:provider_name]
    @badge_class = options[:badge_class]
    @badge_background = options[:badge_background]
    @badge_color = options[:badge_color]
    @badge_text = options[:badge_text]
    @payment_id_field = options[:payment_id_field]
    @identity_fields = Array(options[:identity_fields] || @payment_id_field)
    @refund = options[:refund]
    @purchase_errors = options[:purchase_errors] || {}
    @card = options.fetch(:card, false)
    @complimentary = options.fetch(:complimentary, false)
    @platform_donations = options.fetch(:platform_donations, false)
    @dashboard_help = options[:dashboard_help]
    self.class.all << self
  end

  def self.object(name)
    all.find { |pm| pm.name == name.to_s }
  end

  def self.for_record(record)
    all.find { |pm| pm.matches?(record) }
  end

  def self.badge_for(record)
    all.each do |pm|
      next unless pm.matches?(record)

      badge = pm.badge(record)
      return badge if badge
    end
    nil
  end

  def self.non_card_payment_available?(event)
    all.any? { |pm| !pm.card && !pm.complimentary && pm.available?(event) }
  end

  def self.platform_donation_names
    all.select(&:platform_donations).map(&:name)
  end

  def self.platform_donations_available?(event)
    all.any? { |pm| pm.platform_donations && pm.available?(event) }
  end

  def self.purchase_error_for(error)
    all.each do |pm|
      pm.purchase_errors.each do |klass, spec|
        next unless error.is_a?(klass)

        resolved = spec.respond_to?(:call) ? spec.call(error) : spec
        action, help = resolved.is_a?(Array) ? resolved : [resolved, :default]
        help = pm.dashboard_help if help == :default
        return { method: pm, action: action, help: help, provider: pm.provider_name }
      end
    end
    nil
  end

  def available?(event)
    return false if org_condition && !org_condition.call(event.organisation)

    event_condition.call(event)
  end

  def button_label(event)
    label.respond_to?(:call) ? label.call(event) : label
  end

  def process_payment(order:, event:, account: nil, details_form: nil, ticket_form: nil)
    process.call(order: order, event: event, account: account, details_form: details_form, ticket_form: ticket_form)
  end

  def order_currency_for(event)
    @order_currency&.call(event) || event.currency
  end

  def matches?(record)
    identity_fields.any? { |field| record.try(field).present? }
  end

  def payment_id(record)
    return unless payment_id_field

    record.try(payment_id_field)
  end

  def badge(record)
    text = badge_text.respond_to?(:call) ? badge_text.call(record) : badge_text
    text ||= provider_name if badge_class || badge_background
    return if text.blank?

    style = [
      ("background: #{badge_background} !important" if badge_background),
      ("color: #{badge_color} !important" if badge_color)
    ].compact.join('; ').presence

    { class: badge_background ? nil : (badge_class || 'bg-secondary'), style: style, text: text }
  end
end

EventPaymentMethod.new('rsvp',
                       label: ->(event) { event.rsvp_button_text || 'RSVP' },
                       outline: false,
                       visible: true,
                       complimentary: true,
                       process: ->(**kwargs) { EventPaymentMethod::Rsvp.call(**kwargs) })

EventPaymentMethod.new('coinbase',
                       provider_name: 'Coinbase',
                       badge_background: '#2D53F1',
                       identity_fields: %i[coinbase_checkout_id],
                       org_condition: ->(_org) { false },
                       event_condition: ->(_event) { false })

EventPaymentMethod.new('stripe',
                       label: 'Pay',
                       outline: false,
                       card: true,
                       platform_donations: true,
                       provider_name: 'Stripe',
                       identity_fields: %i[session_id payment_intent],
                       payment_id_field: :payment_intent,
                       org_condition: ->(org) { org.stripe_connect_json || org.stripe_sk },
                       event_condition: ->(event) { FIAT_CURRENCIES.include?(event.currency) },
                       process: ->(**kwargs) { EventPaymentMethod::Stripe.call(**kwargs) },
                       refund: ->(record, **kwargs) { EventPaymentMethod::Stripe.refund(record, **kwargs) },
                       purchase_errors: {
                         Stripe::InvalidRequestError => lambda { |e|
                           e.message&.include?('must add up to at least') ? [:notify, false] : :lock
                         }
                       })

EventPaymentMethod.new('mollie',
                       label: 'Pay with Mollie',
                       provider_name: 'Mollie',
                       badge_background: '#000',
                       badge_color: '#fff',
                       payment_id_field: :mollie_payment_id,
                       org_condition: ->(org) { org.mollie_api_key },
                       event_condition: ->(event) { FIAT_CURRENCIES.include?(event.currency) },
                       process: ->(**kwargs) { EventPaymentMethod::Mollie.call(**kwargs) },
                       refund: ->(record, **kwargs) { EventPaymentMethod::Mollie.refund(record, **kwargs) },
                       purchase_errors: {
                         Mollie::RequestError => lambda { |e|
                           [401, 403].include?(e.status.to_i) ? :lock : :notify
                         }
                       })

EventPaymentMethod.new('paypal',
                       label: 'Pay with PayPal',
                       provider_name: 'PayPal',
                       badge_background: '#003087',
                       badge_color: '#fff',
                       identity_fields: %i[paypal_order_id paypal_capture_id],
                       payment_id_field: :paypal_capture_id,
                       org_condition: ->(org) { org.paypal_client_id && org.paypal_secret },
                       event_condition: ->(event) { FIAT_CURRENCIES.include?(event.currency) },
                       dashboard_help: 'Also, make sure you have added the webhook URL in your PayPal app.',
                       process: ->(**kwargs) { EventPaymentMethod::Paypal.call(**kwargs) },
                       refund: ->(record, **kwargs) { EventPaymentMethod::Paypal.refund(record, **kwargs) },
                       purchase_errors: {
                         Paypal::RequestError => lambda { |e|
                           [401, 403].include?(e.status.to_i) ? :lock : :notify
                         }
                       })

EventPaymentMethod.new('gocardless_instant',
                       label: 'Pay with GoCardless',
                       provider_name: 'GoCardless',
                       badge_background: '#1C1B18',
                       badge_color: '#F1F252',
                       identity_fields: %i[gocardless_payment_request_id gocardless_payment_id],
                       payment_id_field: :gocardless_payment_id,
                       org_condition: ->(org) { org.gocardless_instant_bank_pay && org.gocardless_access_token },
                       event_condition: ->(event) { GOCARDLESS_CURRENCIES.include?(event.currency) },
                       dashboard_help: 'Also, make sure your access token has read-write access.',
                       process: ->(**kwargs) { EventPaymentMethod::GoCardlessInstantBankPay.call(**kwargs) },
                       refund: ->(record, **kwargs) { EventPaymentMethod::GoCardlessInstantBankPay.refund(record, **kwargs) },
                       purchase_errors: {
                         GoCardlessPro::InvalidApiUsageError => :lock,
                         GoCardlessPro::ValidationError => :notify
                       })

EventPaymentMethod.new('gocardless_instalment',
                       label: ->(event) { "Pay in #{event.gocardless_instalment_count} monthly instalments" },
                       provider_name: 'GoCardless',
                       badge_background: '#1C1B18',
                       badge_color: '#F1F252',
                       badge_text: 'GoCardless instalments',
                       identity_fields: %i[gocardless_billing_request_id],
                       org_condition: ->(org) { org.gocardless_instalments && org.gocardless_access_token },
                       event_condition: ->(event) {
                         event.gocardless_instalment_count.to_i >= 2 && GOCARDLESS_CURRENCIES.include?(event.currency)
                       },
                       dashboard_help: 'Also, make sure your access token has read-write access.',
                       process: ->(**kwargs) { EventPaymentMethod::GoCardlessInstalment.call(**kwargs) },
                       purchase_errors: {
                         GoCardlessPro::InvalidApiUsageError => :lock,
                         GoCardlessPro::ValidationError => :notify
                       })

EventPaymentMethod.new('opencollective',
                       label: 'Pay with Open Collective',
                       provider_name: 'Open Collective',
                       badge_class: 'bg-secondary',
                       badge_text: ->(record) { "OC: #{record.oc_secret.split('dandelion:').last}" },
                       identity_fields: %i[oc_secret],
                       org_condition: lambda(&:oc_slug),
                       event_condition: lambda(&:oc_slug),
                       partial: 'purchase/pay_with_opencollective',
                       process: ->(**kwargs) { EventPaymentMethod::OpenCollective.call(**kwargs) })

EventPaymentMethod.new('evm',
                       label: lambda { |event|
                         event.currency.in?(%w[BREAD USD]) ? 'Pay with BREAD on Gnosis Chain' : "Pay with #{event.chain.try(:name)}"
                       },
                       badge_class: 'bg-secondary',
                       badge_text: ->(record) { "EVM: #{record.evm_secret}" },
                       identity_fields: %i[evm_secret],
                       org_condition: lambda(&:evm_address),
                       event_condition: lambda { |event|
                         event.chain && (EVM_CURRENCIES.include?(event.currency) || event.currency == 'USD')
                       },
                       order_currency: ->(event) { event.currency == 'USD' ? 'BREAD' : event.currency },
                       partial: 'purchase/pay_with_evm',
                       process: ->(**kwargs) { EventPaymentMethod::Evm.call(**kwargs) })
