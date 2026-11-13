# Caps how often requests that anyone can make have Dandelion email the same address: sign in codes, and the tickets of
# bookings made for someone who isn't signed in as them. It counts by recipient, not by IP, as a botnet's requests
# come from many IPs but a flood aimed at one person all goes to the same address. Counts are kept in Rack::Attack's
# cache (Redis), by a hash of the address, in fixed windows; if Redis is down, nothing is limited
module RecipientLimit
  LIMITS = {
    sign_in_code: { limit: 5, period: 1.hour },
    guest_booking: { limit: 10, period: 1.hour }
  }.freeze

  SIGN_IN_CODE_WITHHELD = "We've sent several sign in codes to this address in the last hour, so we didn't send another. Use the code in the latest email, or try again later.".freeze

  # Counts one more for the address, and says whether that's still within the limit
  def self.allow?(kind, email)
    limit = LIMITS.fetch(kind)
    Rack::Attack.cache.count("recipient:#{kind}:#{Digest::SHA256.hexdigest(email.to_s.downcase.strip)}", limit[:period]) <= limit[:limit]
  end
end
