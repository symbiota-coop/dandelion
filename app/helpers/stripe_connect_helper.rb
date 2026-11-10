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

  # The organisation a state was minted for, if the current account minted it. Both flows bind the state to the account
  # that started them, so a state (or the callback URL carrying it) passed to someone else is refused, not completed with
  # whichever Stripe account the person who started it authorised
  def organisation_from_stripe_connect_oauth_state(token, personal: false)
    return unless current_account

    data = TokenVerifier.verify(token, purpose: STRIPE_CONNECT_OAUTH_STATE_PURPOSE)
    return unless data

    prefix, org_id, account_id = data.split(':', 3)
    return unless prefix == (personal ? 'stripe_connect_personal' : 'stripe_connect_org') && account_id == current_account.id.to_s

    Organisation.find(org_id)
  end

  private

  def stripe_connect_oauth_state_for(organisation:, personal:)
    options = {
      expires_in: STRIPE_CONNECT_OAUTH_STATE_EXPIRES_IN,
      purpose: STRIPE_CONNECT_OAUTH_STATE_PURPOSE
    }
    prefix = personal ? 'stripe_connect_personal' : 'stripe_connect_org'
    TokenVerifier.generate("#{prefix}:#{organisation.id}:#{current_account.id}", **options)
  end
end
