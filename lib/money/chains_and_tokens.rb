class Chain
  @all = []

  class << self
    attr_accessor :all
  end

  attr_accessor :name, :network_id

  def initialize(name, network_id)
    @name = name
    @network_id = network_id
    self.class.all << self
  end

  def tokens
    Token.all.select { |token| token.chain == self }
  end

  def self.object(name)
    all.find { |chain| chain.name == name }
  end
end

class Token
  @all = []

  class << self
    attr_accessor :all
  end

  attr_accessor :symbol, :contract_address, :chain

  def initialize(symbol, contract_address, chain)
    @symbol = symbol
    @contract_address = contract_address
    @chain = chain
    self.class.all << self
  end

  def self.object(symbol)
    all.find { |token| token.symbol == symbol }
  end

  def self.by_contract_address
    all.each_with_object({}) { |token, hash| hash[token.contract_address] = token.symbol }
  end
end

Chain.new('Gnosis Chain', 100).tap do |chain|
  Token.new('BREAD', '0xa555d5344f6fb6c65da19e403cb4c1ec4a1a5ee3', chain)
end

Chain.new('Celo', 42_220).tap do |chain|
  Token.new('CUSD', '0x765DE816845861e75A25fCA122bb6898B8B1282a', chain)
  Token.new('CEUR', '0xd8763cba276a3738e6de85b4b3bf5fded6d6ca73', chain)
end

Chain.new('Base', 8453).tap do |chain|
  Token.new('USDC', '0x833589fcd6edb6e08f4c7c32d4f71b54bda02913', chain)
end
