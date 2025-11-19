FIAT_CURRENCIES = %w[GBP EUR USD SEK DKK NOK CHF MXN CAD AUD NZD].freeze
COINBASE_CURRENCIES = %w[BTC ETH].freeze
EVM_CURRENCIES = Token.all.map(&:symbol)

MAJOR_CURRENCIES = FIAT_CURRENCIES + COINBASE_CURRENCIES
CRYPTOCURRENCIES = COINBASE_CURRENCIES + EVM_CURRENCIES
CURRENCIES = FIAT_CURRENCIES + CRYPTOCURRENCIES

CURRENCY_OPTIONS = CURRENCIES.map do |currency|
  means = []
  means << 'Stripe' if FIAT_CURRENCIES.include?(currency)
  means << 'Coinbase Commerce' if FIAT_CURRENCIES.include?(currency) || COINBASE_CURRENCIES.include?(currency)
  means << 'Gnosis Chain' if currency == 'USD' # BREAD
  Chain.all.each do |chain|
    means << chain.name if chain.tokens.map(&:symbol).include?(currency)
  end

  ["#{currency} (#{means.uniq.join('/')})", currency]
end

Money::Currency.register({
                           priority: 1,
                           iso_code: 'SEEDS',
                           name: 'Seeds',
                           symbol: 'SEEDS',
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

Money::Currency.register({
                           priority: 1,
                           iso_code: 'SEK',
                           name: 'Swedish Krona',
                           symbol: 'SEK',
                           subunit: 'Öre',
                           subunit_to_unit: 100,
                           decimal_mark: '.',
                           thousands_separator: ','
                         })

Money::Currency.register({
                           priority: 1,
                           iso_code: 'DKK',
                           name: 'Danish Krone',
                           symbol: 'DKK',
                           subunit: 'Øre',
                           subunit_to_unit: 100,
                           decimal_mark: '.',
                           thousands_separator: ','
                         })

Money::Currency.register({
                           priority: 1,
                           iso_code: 'NOK',
                           name: 'Norwegian Krone',
                           symbol: 'NOK',
                           subunit: 'Øre',
                           subunit_to_unit: 100,
                           decimal_mark: '.',
                           thousands_separator: ','
                         })

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
