XDAI_CONTRACT_ADDRESSES = {
  'WXDAI' => '0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d',
  'WETH' => '0x6A023CCd1ff6F2045C3309768eAd9E68F978f6e1',
  'WBTC' => '0x8e5bBbb09Ed1ebdE8674Cda39A0c169401db4252',
  'PAN' => '0x981fB9BA94078a2275A8fc906898ea107B9462A8',
  'HAUS' => '0xb0C5f3100A4d9d9532a4CfD68c55F1AE8da987Eb'
}.freeze

COINBASE_CURRENCIES = %w[BTC ETH].freeze
XDAI_CURRENCIES = XDAI_CONTRACT_ADDRESSES.keys.freeze
CRYPTOCURRENCIES = (COINBASE_CURRENCIES + XDAI_CURRENCIES + %w[SEEDS]).freeze
FIAT_CURRENCIES = %w[GBP EUR USD SEK DKK INR MXN].freeze
CURRENCIES = (FIAT_CURRENCIES + CRYPTOCURRENCIES).freeze

XDAI_CURRENCIES.each do |c|
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
