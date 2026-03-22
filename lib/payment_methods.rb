class PaymentMethod
  @all = []

  class << self
    attr_accessor :all
  end

  attr_accessor :name, :label, :dotted, :visible, :condition, :org_condition, :logo, :url

  def initialize(name, options = {})
    @name = name
    @label = options[:label] || name.capitalize
    @dotted = options.fetch(:dotted, true)
    @visible = options.fetch(:visible, false)
    @condition = options[:condition] || ->(_event) { true }
    @org_condition = options[:org_condition]
    @logo = options[:logo]
    @url = options[:url]
    self.class.all << self
  end

  def self.object(name)
    all.find { |pm| pm.name == name }
  end

  def available?(event)
    condition.call(event)
  end

  def button_label(event)
    label.respond_to?(:call) ? label.call(event) : label
  end
end

PaymentMethod.new('rsvp',
                   label: ->(event) { event.rsvp_button_text || 'RSVP' },
                   dotted: false,
                   visible: true)

PaymentMethod.new('stripe',
                   label: 'Pay',
                   dotted: false,
                   org_condition: ->(org) { org.stripe_connect_json || org.stripe_pk },
                   condition: ->(event) {
                     (event.organisation.stripe_connect_json || event.organisation.stripe_sk) &&
                       FIAT_CURRENCIES.include?(event.currency)
                   },
                   logo: 'stripe.png',
                   url: 'https://stripe.com/')

PaymentMethod.new('gocardless',
                   label: 'Pay with GoCardless',
                   org_condition: ->(org) { org.gocardless_instant_bank_pay && org.gocardless_access_token },
                   condition: ->(event) {
                     event.organisation.gocardless_instant_bank_pay &&
                       event.organisation.gocardless_access_token &&
                       FIAT_CURRENCIES.include?(event.currency)
                   },
                   logo: 'gocardless.png',
                   url: 'https://gocardless.com/')

PaymentMethod.new('opencollective',
                   label: 'Pay with Open Collective',
                   org_condition: ->(org) { org.oc_slug },
                   condition: ->(event) { event.oc_slug },
                   logo: 'opencollective.png',
                   url: 'https://opencollective.com/')

PaymentMethod.new('evm',
                   label: ->(event) {
                     event.currency.in?(%w[BREAD USD]) ? 'Pay with BREAD on Gnosis Chain' : "Pay with #{event.chain.try(:name)}"
                   },
                   org_condition: ->(org) { org.evm_address },
                   condition: ->(event) {
                     event.organisation.evm_address &&
                       (EVM_CURRENCIES.include?(event.currency) || event.currency == 'USD')
                   })
