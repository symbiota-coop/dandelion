FIAT_CURRENCIES = %w[GBP EUR USD SEK DKK NOK CHF MXN CAD AUD NZD JPY SGD PLN].freeze
EVM_CURRENCIES = Token.all.map(&:symbol)

module FiatCurrency
  module_function

  def minimum_unit_amount(currency)
    return nil unless FIAT_CURRENCIES.include?(currency)

    amount = Money.new(100, 'GBP').exchange_to(currency).cents.to_f / 100
    return nil unless amount.positive?

    power = Math.log10(amount).floor
    10**power
  end
end

CURRENCIES = FIAT_CURRENCIES + EVM_CURRENCIES

CURRENCY_OPTIONS = CURRENCIES.map do |currency|
  if FIAT_CURRENCIES.include?(currency)
    [currency, currency]
  else
    means = Chain.all.filter_map { |c| c.name if c.tokens.map(&:symbol).include?(currency) }.uniq.join('/')
    ["#{currency} (#{means})", currency]
  end
end

Money::Currency.with_options(priority: 1, symbol_first: true, subunit_to_unit: 100, decimal_mark: '.', thousands_separator: ',') do |currency|
  currency.register(iso_code: 'ETH', name: 'Ethereum', symbol: 'Ξ', subunit: 'Cent')
  currency.register(iso_code: 'SEEDS', name: 'Seeds', symbol: 'SEEDS ', subunit: 'Cent')
  currency.register(iso_code: 'SEK', name: 'Swedish Krona', symbol: 'SEK ', subunit: 'Öre')
  currency.register(iso_code: 'DKK', name: 'Danish Krone', symbol: 'DKK ', subunit: 'Øre')
  currency.register(iso_code: 'NOK', name: 'Norwegian Krone', symbol: 'NOK ', subunit: 'Øre')

  EVM_CURRENCIES.each do |c|
    currency.register(iso_code: c, name: c, symbol: "#{c} ", subunit: 'Cent')
  end
end
