class PaymentMethod
  @all = []

  class << self
    attr_accessor :all
  end

  attr_accessor :name, :label, :dotted, :visible, :condition, :org_condition, :process, :partial

  def initialize(name, options = {})
    @name = name
    @label = options[:label] || name.capitalize
    @dotted = options.fetch(:dotted, true)
    @visible = options.fetch(:visible, false)
    @condition = options[:condition] || ->(_event) { true }
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
                  process: ->(**kwargs) { PaymentMethod::Rsvp.call(**kwargs) })

PaymentMethod.new('stripe',
                  label: 'Pay',
                  dotted: false,
                  org_condition: ->(org) { org.stripe_connect_json || org.stripe_pk },
                  condition: lambda { |event|
                    (event.organisation.stripe_connect_json || event.organisation.stripe_sk) &&
                      FIAT_CURRENCIES.include?(event.currency)
                  },
                  process: ->(**kwargs) { PaymentMethod::Stripe.call(**kwargs) })

PaymentMethod.new('gocardless',
                  label: 'Pay with GoCardless',
                  org_condition: ->(org) { org.gocardless_instant_bank_pay && org.gocardless_access_token },
                  condition: lambda { |event|
                    event.organisation.gocardless_instant_bank_pay &&
                      event.organisation.gocardless_access_token &&
                      FIAT_CURRENCIES.include?(event.currency)
                  },
                  process: ->(**kwargs) { PaymentMethod::GoCardless.call(**kwargs) })

PaymentMethod.new('opencollective',
                  label: 'Pay with Open Collective',
                  org_condition: ->(org) { org.oc_slug },
                  condition: ->(event) { event.oc_slug },
                  partial: 'purchase/pay_with_opencollective',
                  process: ->(**kwargs) { PaymentMethod::OpenCollective.call(**kwargs) })

PaymentMethod.new('evm',
                  label: lambda { |event|
                    event.currency.in?(%w[BREAD USD]) ? 'Pay with BREAD on Gnosis Chain' : "Pay with #{event.chain.try(:name)}"
                  },
                  org_condition: ->(org) { org.evm_address },
                  condition: lambda { |event|
                    event.chain &&
                      event.organisation.evm_address &&
                      (EVM_CURRENCIES.include?(event.currency) || event.currency == 'USD')
                  },
                  order_currency: ->(event) { event.currency == 'USD' ? 'BREAD' : event.currency },
                  partial: 'purchase/pay_with_evm',
                  process: ->(**kwargs) { PaymentMethod::Evm.call(**kwargs) })
