# What tests don't reach outside: Mailgun, DNS for email domains and geocoding

# No test reaches Mailgun: Mailer sends through an organisation's own account whenever it has an API key, even here, so
# an email a test doesn't record (recorded_email, recorded_emails) would otherwise really be sent
module RefuseMailgunInTests
  %i[get post put delete].each do |verb|
    define_method(verb) { |*| raise "A test tried to reach Mailgun (#{verb.upcase}): record the email with recorded_email(s)" }
  end
end
Mailgun::Client.prepend(RefuseMailgunInTests)

# Tests don't look email domains up in DNS: it's slow, and a domain that stops resolving fails tests that aren't about it
EmailAddress::Config.configure(host_validation: :syntax)

# Configure Geocoder for testing (avoid real API calls)
Geocoder.configure(lookup: :test)
Geocoder::Lookup::Test.set_default_stub([{ 'coordinates' => [59.3251, 18.0685] }]) # Gamla Stan coords (111 28, Sweden)
