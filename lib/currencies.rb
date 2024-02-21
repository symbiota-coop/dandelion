GNOSIS_CONTRACT_ADDRESSES = {
  'WXDAI' => '0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d'
}.freeze
GNOSIS_CURRENCIES = GNOSIS_CONTRACT_ADDRESSES.keys.freeze

CELO_CONTRACT_ADDRESSES = {
  'CUSD' => '0x765DE816845861e75A25fCA122bb6898B8B1282a'
}.freeze
CELO_CURRENCIES = CELO_CONTRACT_ADDRESSES.keys.freeze

OPTIMISM_CONTRACT_ADDRESSES = {
  'DAI' => '0xda10009cbd5d07dd0cecc66161fc93d7c9000da1',
  'WETH' => '0x4200000000000000000000000000000000000006'
}.freeze
OPTIMISM_CURRENCIES = OPTIMISM_CONTRACT_ADDRESSES.keys.freeze

POLYGON_CONTRACT_ADDRESSES = {
  'BREAD' => '0x11d9efDf4Ab4A3bfabf5C7089F56AA4F059AA14C'
}.freeze
POLYGON_CURRENCIES = POLYGON_CONTRACT_ADDRESSES.keys.freeze

ARBITRUM_CONTRACT_ADDRESSES = {
  'ARB' => '0x912ce59144191c1204e64559fe8253a0e49e6548'
}.freeze
ARBITRUM_CURRENCIES = ARBITRUM_CONTRACT_ADDRESSES.keys.freeze

EVM_CONTRACT_ADDRESSES = {}.merge(GNOSIS_CONTRACT_ADDRESSES).merge(CELO_CONTRACT_ADDRESSES).merge(OPTIMISM_CONTRACT_ADDRESSES).merge(POLYGON_CONTRACT_ADDRESSES).merge(ARBITRUM_CONTRACT_ADDRESSES).freeze
EVM_CURRENCIES = (GNOSIS_CURRENCIES + CELO_CURRENCIES + OPTIMISM_CURRENCIES + POLYGON_CURRENCIES + ARBITRUM_CURRENCIES).freeze
EVM_NETWORK_IDS = { 'GNOSIS' => 100, 'CELO' => 42_220, 'OPTIMISM' => 10, 'POLYGON' => 137, 'ARBITRUM' => 42_161 }.freeze

COINBASE_CURRENCIES = %w[BTC ETH].freeze
CRYPTOCURRENCIES = (COINBASE_CURRENCIES + EVM_CURRENCIES + %w[SEEDS]).freeze

FIAT_CURRENCIES = %w[GBP EUR USD SEK DKK MXN CAD].freeze

MAJOR_CURRENCIES = (FIAT_CURRENCIES + COINBASE_CURRENCIES).freeze
CURRENCIES = (FIAT_CURRENCIES + CRYPTOCURRENCIES).freeze
CURRENCIES_HASH = CURRENCIES.map do |currency|
  ["#{currency} (#{[
    ('Stripe' if FIAT_CURRENCIES.include?(currency)),
    ('Coinbase Commerce' if FIAT_CURRENCIES.include?(currency) || COINBASE_CURRENCIES.include?(currency)),
    ('Gnosis Chain' if GNOSIS_CURRENCIES.include?(currency)),
    ('Celo' if CELO_CURRENCIES.include?(currency)),
    ('Optimism' if OPTIMISM_CURRENCIES.include?(currency)),
    ('Polygon' if POLYGON_CURRENCIES.include?(currency) || currency == 'USD'),
    ('Arbitrum One' if ARBITRUM_CURRENCIES.include?(currency)),
    ('SEEDS' if currency == 'SEEDS')
  ].compact.join('/')})", currency]
end

CURRENCIES_HASH_UNBAKED = CURRENCIES.map do |currency|
  ["#{currency} (#{[
    ('Stripe' if FIAT_CURRENCIES.include?(currency)),
    ('Coinbase Commerce' if FIAT_CURRENCIES.include?(currency) || COINBASE_CURRENCIES.include?(currency)),
    ('Gnosis Chain' if GNOSIS_CURRENCIES.include?(currency)),
    ('Celo' if CELO_CURRENCIES.include?(currency)),
    ('Optimism' if OPTIMISM_CURRENCIES.include?(currency)),
    ('Polygon' if POLYGON_CURRENCIES.include?(currency)),
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
