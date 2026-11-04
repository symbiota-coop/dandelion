STRIPE_CONNECT_OAUTH_STATE_PURPOSE = 'stripe_connect'.freeze
STRIPE_CONNECT_OAUTH_STATE_EXPIRES_IN = 15.minutes
STRIPE_CONNECT_LINK_EXPIRED_MESSAGE = 'That Stripe connection link has already been used or has expired. Please try connecting again.'.freeze

Dandelion::App.helpers do
  def stripe_connect_oauth_url(organisation:, client_id:, personal: false)
    state = stripe_connect_oauth_state_for(organisation:, personal:)
    "https://connect.stripe.com/oauth/authorize?response_type=code&client_id=#{CGI.escape(client_id.to_s)}&scope=read_write&state=#{CGI.escape(state)}"
  end

  # Trades an OAuth code for the account's Stripe connection JSON. Returns nil when the code is spent or expired: Stripe's
  # codes are single-use, so that's a reload or back button, not a fault. Raises on any other failure
  def stripe_connect_token_exchange(client_secret:, code:)
    response = Faraday.new { |f| f.request :url_encoded }.post(
      'https://connect.stripe.com/oauth/token',
      client_secret:, code:, grant_type: 'authorization_code'
    )
    return response.body if response.success?

    stripe_error = begin
      JSON.parse(response.body)['error']
    rescue JSON::ParserError
      nil
    end
    return if stripe_error == 'invalid_grant'

    raise "Stripe OAuth token exchange failed with status #{response.status} (#{stripe_error || 'no error code'})"
  end

  def organisation_from_stripe_connect_oauth_state(token, personal: false)
    data = TokenVerifier.verify(token, purpose: STRIPE_CONNECT_OAUTH_STATE_PURPOSE)
    return unless data

    if personal
      prefix, org_id, account_id = data.split(':', 3)
      return unless prefix == 'stripe_connect_personal' && account_id == current_account.id.to_s

      Organisation.find(org_id)
    else
      prefix, org_id = data.split(':', 2)
      return unless prefix == 'stripe_connect_org'

      Organisation.find(org_id)
    end
  end

  private

  def stripe_connect_oauth_state_for(organisation:, personal:)
    options = {
      expires_in: STRIPE_CONNECT_OAUTH_STATE_EXPIRES_IN,
      purpose: STRIPE_CONNECT_OAUTH_STATE_PURPOSE
    }
    if personal
      TokenVerifier.generate("stripe_connect_personal:#{organisation.id}:#{current_account.id}", **options)
    else
      TokenVerifier.generate("stripe_connect_org:#{organisation.id}", **options)
    end
  end
end
