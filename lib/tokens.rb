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

Chain.new('Gnosis Chain', 100)
Chain.new('Celo', 42_220)
Chain.new('Optimism', 10)
Chain.new('Polygon', 137)
Chain.new('Arbitrum One', 42_161)

Token.new('WXDAI', '0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d', Chain.object('Gnosis Chain'))
Token.new('CUSD', '0x765DE816845861e75A25fCA122bb6898B8B1282a', Chain.object('Celo'))
Token.new('DAI', '0xda10009cbd5d07dd0cecc66161fc93d7c9000da1', Chain.object('Optimism'))
Token.new('WETH', '0x4200000000000000000000000000000000000006', Chain.object('Optimism'))
Token.new('BREAD', '0x11d9efDf4Ab4A3bfabf5C7089F56AA4F059AA14C', Chain.object('Polygon'))
Token.new('USDGLO', '0x4f604735c1cf31399c6e711d5962b2b3e0225ad3', Chain.object('Arbitrum One'))
