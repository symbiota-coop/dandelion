class GatheringPaymentMethod
  @all = []

  class << self
    attr_accessor :all
  end

  attr_accessor :name, :label, :gathering_condition, :process

  def initialize(name, options = {})
    @name = name
    @label = options[:label] || name.capitalize
    @gathering_condition = options[:gathering_condition] || ->(_gathering) { true }
    @process = options[:process]
    self.class.all << self
  end

  def self.object(name)
    all.find { |pm| pm.name == name.to_s }
  end

  def available?(gathering)
    gathering_condition.call(gathering)
  end

  def button_label(gathering)
    label.respond_to?(:call) ? label.call(gathering) : label
  end

  def process_payment(gathering:, membership:, account:, params:)
    process.call(gathering: gathering, membership: membership, account: account, params: params)
  end
end

GatheringPaymentMethod.new('stripe',
                           label: 'Pay with card',
                           gathering_condition: ->(g) { g.stripe_sk && FIAT_CURRENCIES.include?(g.currency) },
                           process: ->(**kwargs) { GatheringPaymentMethod::Stripe.call(**kwargs) })

GatheringPaymentMethod.new('evm',
                           label: lambda { |g| "Pay with #{g.chain.name}" },
                           gathering_condition: ->(g) { g.evm_address && g.chain && EVM_CURRENCIES.include?(g.currency) },
                           process: ->(**kwargs) { GatheringPaymentMethod::Evm.call(**kwargs) })
