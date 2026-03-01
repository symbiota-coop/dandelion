class DandelionBank < Money::Bank::VariableExchange
  TTL = 3600 # 1 hour

  def initialize(*)
    super
    @rates_updated_at = nil
  end

  def get_rate(iso_from, iso_to, *)
    update_rates if rates_expired?
    super
  end

  def update_rates
    usd_rates = begin
      fetch_uphold_rates
    rescue Faraday::Error, JSON::ParserError
      fetch_fallback_rates
    end
    currencies = usd_rates.keys

    # Add direct USD pairs
    usd_rates.each do |currency, rate|
      add_rate('USD', currency, rate)
      add_rate(currency, 'USD', 1.0 / rate)
    end

    # Add cross rates via USD (e.g. GBP→EUR = GBP→USD * USD→EUR)
    currencies.each do |from|
      currencies.each do |to|
        next if from == to

        add_rate(from, to, (1.0 / usd_rates[from]) * usd_rates[to])
      end
    end

    @rates_updated_at = Time.now
  rescue StandardError => e
    raise unless @rates_updated_at

    Honeybadger.notify(e)
  end

  private

  def rates_expired?
    @rates_updated_at.nil? || (Time.now - @rates_updated_at) > TTL
  end

  # Returns { 'GBP' => 0.79, 'EUR' => 0.92, 'BTC' => 0.000015, ... } (rates per 1 USD)
  def http
    @http ||= Faraday.new { |f| f.options.timeout = 10; f.options.open_timeout = 5; f.response :json }
  end

  def fetch_uphold_rates
    data = http.get('https://api.uphold.com/v0/ticker/USD').body
    rates = {}
    known = Money::Currency.table.keys.map { |k| k.to_s.upcase }
    data.each do |ticker|
      pair = ticker['pair']
      next unless pair.start_with?('USD')

      currency = pair.delete_prefix('USD')
      next unless known.include?(currency)

      rates[currency] = (ticker['ask'].to_f + ticker['bid'].to_f) / 2
    end
    rates
  end

  def fetch_fallback_rates
    rates = http.get('https://api.frankfurter.app/latest?from=USD').body['rates']

    data = http.get('https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd').body
    rates['BTC'] = 1.0 / data['bitcoin']['usd']
    rates['ETH'] = 1.0 / data['ethereum']['usd']
    rates
  end
end
