# What tests don't reach outside: Mailgun, Redis, DNS for email domains, geocoding and exchange rates

# No test reaches Mailgun: Mailer sends through an organisation's own account whenever it has an API key, even here, so
# an email a test doesn't record (recorded_email, recorded_emails) would otherwise really be sent
module RefuseMailgunInTests
  %i[get post put delete].each do |verb|
    define_method(verb) { |*| raise "A test tried to reach Mailgun (#{verb.upcase}): record the email with recorded_email(s)" }
  end
end
Mailgun::Client.prepend(RefuseMailgunInTests)

# Rack::Attack's counts (RecipientLimit, the blocklists) are kept in memory rather than Redis, which tests don't have:
# without it the store counts nothing. reset! clears them between tests
Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new

# Tests don't look email domains up in DNS: it's slow, and a domain that stops resolving fails tests that aren't about it
EmailAddress::Config.configure(host_validation: :syntax)

# Configure Geocoder for testing (avoid real API calls)
Geocoder.configure(lookup: :test)
Geocoder::Lookup::Test.set_default_stub([{ 'coordinates' => [59.3251, 18.0685] }]) # Gamla Stan coords (111 28, Sweden)

# Tests convert currencies at fixed rates rather than fetching Uphold's (or Frankfurter's and CoinGecko's): the live
# rates need the network, and change, so a converted price would too. Rates are per 1 USD, as Uphold's are, and the
# stablecoins follow the currencies they're pegged to (STABLECOIN_PEGS). A test that needs rates of its own stubs
# Money.default_bank.get_rate
module FixedExchangeRatesInTests
  RATES_PER_USD = {
    'GBP' => 0.8, 'EUR' => 0.9, 'SEK' => 10.0, 'DKK' => 7.0, 'NOK' => 10.0, 'CHF' => 0.9, 'MXN' => 18.0,
    'CAD' => 1.4, 'AUD' => 1.5, 'NZD' => 1.7, 'SGD' => 1.3, 'PLN' => 4.0, 'BTC' => 0.00001, 'ETH' => 0.0004
  }.freeze

  private

  def fetch_uphold_rates
    RATES_PER_USD.dup
  end

  def fetch_fallback_rates
    raise 'A test tried to fetch exchange rates'
  end
end
DandelionBank.prepend(FixedExchangeRatesInTests)
