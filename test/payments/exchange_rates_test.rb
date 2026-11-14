require_relative '../test_config'
require_relative '../helpers/error_reporting_helpers'

# Fetching exchange rates (DandelionBank): Uphold's USD ticker, falling back to Frankfurter and CoinGecko, and what the
# bank keeps when they fail. Every other test converts at fixed rates (FixedExchangeRatesInTests); these run the real
# fetching on a bank of their own, with its HTTP answered by Faraday's test adapter, so nothing reaches the network
class PaymentsExchangeRatesTest < ActiveSupport::TestCase
  include ErrorReportingHelpers

  UPHOLD_URL = 'https://api.uphold.com/v0/ticker/USD'.freeze
  FRANKFURTER_URL = 'https://api.frankfurter.app/latest?from=USD'.freeze
  COINGECKO_URL = 'https://api.coingecko.com/api/v3/simple/price?ids=bitcoin,ethereum&vs_currencies=usd'.freeze
  JSON_HEADERS = { 'Content-Type' => 'application/json' }.freeze

  UPHOLD_TICKERS = [
    { 'pair' => 'USDGBP', 'ask' => '0.81', 'bid' => '0.79', 'currency' => 'GBP' },
    { 'pair' => 'USDEUR', 'ask' => '0.91', 'bid' => '0.89', 'currency' => 'EUR' },
    { 'pair' => 'USDBTC', 'ask' => '0.0000101', 'bid' => '0.0000099', 'currency' => 'BTC' },
    { 'pair' => 'GBPUSD', 'ask' => '1.26', 'bid' => '1.24', 'currency' => 'USD' },
    { 'pair' => 'USDXYZ', 'ask' => '5', 'bid' => '5', 'currency' => 'XYZ' }
  ].freeze

  # A DandelionBank that fetches for real, past FixedExchangeRatesInTests (prepended to DandelionBank, so the bank's
  # own methods are its super_method), its connection keeping the bank's middleware but answered by the stubs
  def fetching_bank(stubs)
    bank = DandelionBank.new
    %i[fetch_uphold_rates fetch_fallback_rates].each do |name|
      bank.singleton_class.define_method(name, DandelionBank.instance_method(name).super_method)
    end
    bank.send(:http).builder.adapter(:test, stubs)
    bank
  end

  def json(body)
    [200, JSON_HEADERS, body.to_json]
  end

  def uphold_down(stub)
    stub.get(UPHOLD_URL) { raise Faraday::ConnectionFailed, 'Connection refused' }
  end

  def frankfurter_rates(stub, rates = { 'GBP' => 0.8, 'EUR' => 0.9, 'XYZ' => 5.0 })
    stub.get(FRANKFURTER_URL) { json('amount' => 1.0, 'base' => 'USD', 'rates' => rates) }
  end

  def rate(bank, from, to)
    bank.get_rate(from, to)
  end

  test 'uphold tickers become mid rates per USD, ignoring other pairs and unknown currencies' do
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new { |stub| stub.get(UPHOLD_URL) { json(UPHOLD_TICKERS) } })

    assert_in_delta 0.8, rate(bank, 'USD', 'GBP')
    assert_in_delta 0.9, rate(bank, 'USD', 'EUR')
    assert_in_delta 0.00001, rate(bank, 'USD', 'BTC'), 1e-12
    assert_in_delta 1.25, rate(bank, 'GBP', 'USD')
    assert_equal %w[BTC EUR GBP], bank.send(:fetch_uphold_rates).keys.sort
    assert_empty(bank.rates.keys.grep(/XYZ/))
  end

  test 'the bank converts with the fetched rates, through USD and between other currencies' do
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new { |stub| stub.get(UPHOLD_URL) { json(UPHOLD_TICKERS) } })

    assert_equal Money.new(800, 'GBP'), bank.exchange_with(Money.new(1000, 'USD'), 'GBP')
    assert_equal Money.new(1000, 'USD'), bank.exchange_with(Money.new(800, 'GBP'), 'USD')
    assert_in_delta 1.125, rate(bank, 'GBP', 'EUR')
    assert_equal Money.new(1125, 'EUR'), bank.exchange_with(Money.new(1000, 'GBP'), 'EUR')
    assert_in_delta 0.00001 / 0.8, rate(bank, 'GBP', 'BTC'), 1e-12
  end

  test 'stablecoins take the rate of the currency they are pegged to' do
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new { |stub| stub.get(UPHOLD_URL) { json(UPHOLD_TICKERS) } })

    assert_in_delta 1.0, rate(bank, 'USD', 'USDC')
    assert_in_delta 1.0, rate(bank, 'DAI', 'USD')
    assert_in_delta 0.9, rate(bank, 'USD', 'CEUR')
    assert_in_delta 1.0, rate(bank, 'CEUR', 'EUR')
    assert_in_delta 0.8 / 0.9, rate(bank, 'CEUR', 'GBP')
  end

  test 'rates are fetched again only once an hour has passed' do
    requests = 0
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(UPHOLD_URL) do
        requests += 1
        json(UPHOLD_TICKERS.map { |ticker| ticker['pair'] == 'USDGBP' && requests > 1 ? ticker.merge('ask' => '0.7', 'bid' => '0.7') : ticker })
      end
    end)

    travel_to Time.utc(2026, 11, 14, 12) do
      assert_in_delta 0.8, rate(bank, 'USD', 'GBP')
    end
    travel_to Time.utc(2026, 11, 14, 12, 59) do
      assert_in_delta 0.8, rate(bank, 'USD', 'GBP')
      assert_equal 1, requests
    end
    travel_to Time.utc(2026, 11, 14, 13, 1) do
      assert_in_delta 0.7, rate(bank, 'USD', 'GBP')
      assert_equal 2, requests
    end
  end

  test 'when uphold fails, frankfurter gives the fiat rates and coingecko bitcoin and ether' do
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new do |stub|
      uphold_down(stub)
      frankfurter_rates(stub)
      stub.get(COINGECKO_URL) { json('bitcoin' => { 'usd' => 100_000 }, 'ethereum' => { 'usd' => 2500 }) }
    end)

    assert_in_delta 0.8, rate(bank, 'USD', 'GBP')
    assert_in_delta 0.9 / 0.8, rate(bank, 'GBP', 'EUR')
    assert_in_delta 0.00001, rate(bank, 'USD', 'BTC'), 1e-12
    assert_in_delta 0.0004, rate(bank, 'USD', 'ETH'), 1e-12
    assert_in_delta 2500.0, rate(bank, 'ETH', 'USD')
    assert_empty(bank.rates.keys.grep(/XYZ/))
  end

  test 'uphold answering with an error falls back too' do
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(UPHOLD_URL) { [503, JSON_HEADERS, { 'code' => 'service_unavailable' }.to_json] }
      frankfurter_rates(stub)
      stub.get(COINGECKO_URL) { json('bitcoin' => { 'usd' => 100_000 }, 'ethereum' => { 'usd' => 2500 }) }
    end)

    assert_in_delta 0.8, rate(bank, 'USD', 'GBP')
    assert_in_delta 0.00001, rate(bank, 'USD', 'BTC'), 1e-12
  end

  test 'coingecko prices of zero or missing are skipped' do
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new do |stub|
      uphold_down(stub)
      frankfurter_rates(stub)
      stub.get(COINGECKO_URL) { json('bitcoin' => { 'usd' => 0 }) }
    end)

    assert_in_delta 0.8, rate(bank, 'USD', 'GBP')
    assert_nil bank.get_rate('USD', 'BTC')
    assert_nil bank.get_rate('USD', 'ETH')
  end

  test 'a coingecko failure keeps the frankfurter rates and is reported' do
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new do |stub|
      uphold_down(stub)
      frankfurter_rates(stub)
      stub.get(COINGECKO_URL) { raise Faraday::TimeoutError, 'timed out' }
    end)

    reported = reported_exceptions { bank.update_rates }

    assert_in_delta 0.8, rate(bank, 'USD', 'GBP')
    assert_nil bank.get_rate('USD', 'BTC')
    assert_equal [Faraday::TimeoutError], reported.map(&:class)
  end

  test 'when every service fails and there were no rates, it raises' do
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new do |stub|
      uphold_down(stub)
      stub.get(FRANKFURTER_URL) { [200, JSON_HEADERS, 'not json'] }
    end)

    reported = reported_exceptions do
      assert_raises(Faraday::ParsingError) { bank.get_rate('USD', 'GBP') }
    end
    assert_empty reported
  end

  test 'when every service fails and there were rates, it keeps them and reports' do
    up = true
    bank = fetching_bank(Faraday::Adapter::Test::Stubs.new do |stub|
      stub.get(UPHOLD_URL) do
        raise Faraday::ConnectionFailed, 'Connection refused' unless up

        json(UPHOLD_TICKERS)
      end
      stub.get(FRANKFURTER_URL) { raise Faraday::ConnectionFailed, 'Connection refused' }
    end)

    travel_to Time.utc(2026, 11, 14, 12) do
      assert_in_delta 0.8, rate(bank, 'USD', 'GBP')
    end
    up = false
    travel_to Time.utc(2026, 11, 14, 13, 1) do
      reported = reported_exceptions { assert_in_delta 0.8, rate(bank, 'USD', 'GBP') }
      assert_equal [Faraday::ConnectionFailed], reported.map(&:class)
    end
  end
end
