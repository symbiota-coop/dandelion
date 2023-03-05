XDAI_CONTRACT_ADDRESSES = {
  'WXDAI' => '0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d',
  'WETH' => '0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1',
  'WBTC' => '0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252'
}.freeze
XDAI_CURRENCIES = XDAI_CONTRACT_ADDRESSES.keys.freeze

CELO_CONTRACT_ADDRESSES = {
  'CUSD' => '0x765DE816845861e75A25fCA122bb6898B8B1282a'
}.freeze
CELO_CURRENCIES = CELO_CONTRACT_ADDRESSES.keys.freeze

EVM_CONTRACT_ADDRESSES = {}.merge(XDAI_CONTRACT_ADDRESSES).merge(CELO_CONTRACT_ADDRESSES).freeze
EVM_CURRENCIES = (XDAI_CURRENCIES + CELO_CURRENCIES).freeze
EVM_NETWORK_IDS = { 'XDAI' => 100, 'CELO' => 42_220 }.freeze

COINBASE_CURRENCIES = %w[BTC ETH].freeze
CRYPTOCURRENCIES = (COINBASE_CURRENCIES + EVM_CURRENCIES + %w[SEEDS]).freeze

FIAT_CURRENCIES = %w[GBP EUR USD SEK DKK INR MXN CAD].freeze

MAJOR_CURRENCIES = (FIAT_CURRENCIES + COINBASE_CURRENCIES).freeze
CURRENCIES = (FIAT_CURRENCIES + CRYPTOCURRENCIES).freeze
CURRENCIES_HASH = CURRENCIES.map do |currency|
  ["#{currency} (#{[
    ('Stripe' if FIAT_CURRENCIES.include?(currency)),
    ('Coinbase Commerce' if FIAT_CURRENCIES.include?(currency) || COINBASE_CURRENCIES.include?(currency)),
    ('Gnosis Chain' if XDAI_CURRENCIES.include?(currency)),
    ('Celo' if CELO_CURRENCIES.include?(currency) || currency == 'USD'),
    ('SEEDS' if currency == 'SEEDS')
  ].compact.join('/')})", currency]
end

CURRENCIES_HASH_WITHOUT_CELO_USD = CURRENCIES.map do |currency|
  ["#{currency} (#{[
    ('Stripe' if FIAT_CURRENCIES.include?(currency)),
    ('Coinbase Commerce' if FIAT_CURRENCIES.include?(currency) || COINBASE_CURRENCIES.include?(currency)),
    ('Gnosis Chain' if XDAI_CURRENCIES.include?(currency)),
    ('Celo' if CELO_CURRENCIES.include?(currency)),
    ('SEEDS' if currency == 'SEEDS')
  ].compact.join('/')})", currency]
end

EVM_CURRENCIES.each do |c|
  Money::Currency.register({
                             priority: 1,
                             iso_code: c,
                             name: c,
                             symbol: c,
                             subunit: 'Cent',
                             subunit_to_unit: 100,
                             decimal_mark: '.',
                             thousands_separator: ','
                           })
end

Money::Currency.register({
                           priority: 1,
                           iso_code: 'SEEDS',
                           name: 'Seeds',
                           symbol: 'Seeds',
                           subunit: 'Cent',
                           subunit_to_unit: 100,
                           decimal_mark: '.',
                           thousands_separator: ','
                         })

Money::Currency.register({
                           priority: 1,
                           iso_code: 'ETH',
                           name: 'Ethereum',
                           symbol: 'Ξ',
                           subunit: 'Cent',
                           subunit_to_unit: 100,
                           decimal_mark: '.',
                           thousands_separator: ','
                         })
