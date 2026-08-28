module StripeOpts
  def self.call(api_key: ENV['STRIPE_SK'], stripe_account: nil)
    {
      api_key: api_key,
      stripe_version: ENV['STRIPE_API_VERSION'],
      stripe_account: stripe_account
    }.compact
  end
end
