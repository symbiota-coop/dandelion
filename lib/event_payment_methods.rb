class EventPaymentMethod
  @all = []

  class << self
    attr_accessor :all
  end

  attr_accessor :name, :label, :dotted, :visible, :event_condition, :org_condition, :process, :partial

  def initialize(name, options = {})
    @name = name
    @label = options[:label] || name.capitalize
    @dotted = options.fetch(:dotted, true)
    @visible = options.fetch(:visible, false)
    @event_condition = options[:event_condition] || ->(_event) { true }
    @org_condition = options[:org_condition]
    @process = options[:process]
    @partial = options[:partial]
    @order_currency = options[:order_currency]
    self.class.all << self
  end

  def self.object(name)
    all.find { |pm| pm.name == name.to_s }
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
end

EventPaymentMethod.new('rsvp',
                       label: ->(event) { event.rsvp_button_text || 'RSVP' },
                       dotted: false,
                       visible: true,
                       process: ->(**kwargs) { EventPaymentMethod::Rsvp.call(**kwargs) })

EventPaymentMethod.new('stripe',
                       label: 'Pay',
                       dotted: false,
                       org_condition: ->(org) { org.stripe_connect_json || org.stripe_sk },
                       event_condition: ->(event) { FIAT_CURRENCIES.include?(event.currency) },
                       process: ->(**kwargs) { EventPaymentMethod::Stripe.call(**kwargs) })

EventPaymentMethod.new('gocardless',
                       label: 'Pay with GoCardless',
                       org_condition: ->(org) { org.gocardless_instant_bank_pay && org.gocardless_access_token },
                       event_condition: ->(event) { FIAT_CURRENCIES.include?(event.currency) },
                       process: ->(**kwargs) { EventPaymentMethod::GoCardless.call(**kwargs) })

EventPaymentMethod.new('opencollective',
                       label: 'Pay with Open Collective',
                       org_condition: lambda(&:oc_slug),
                       event_condition: lambda(&:oc_slug),
                       partial: 'purchase/pay_with_opencollective',
                       process: ->(**kwargs) { EventPaymentMethod::OpenCollective.call(**kwargs) })

EventPaymentMethod.new('evm',
                       label: lambda { |event|
                         event.currency.in?(%w[BREAD USD]) ? 'Pay with BREAD on Gnosis Chain' : "Pay with #{event.chain.try(:name)}"
                       },
                       org_condition: lambda(&:evm_address),
                       event_condition: lambda { |event|
                         event.chain && (EVM_CURRENCIES.include?(event.currency) || event.currency == 'USD')
                       },
                       order_currency: ->(event) { event.currency == 'USD' ? 'BREAD' : event.currency },
                       partial: 'purchase/pay_with_evm',
                       process: ->(**kwargs) { EventPaymentMethod::Evm.call(**kwargs) })
