Dandelion::App.helpers do
  def stripe_connect_oauth_url(organisation:, client_id:, personal: false)
    state = stripe_connect_oauth_state_for(organisation:, personal:)
    "https://connect.stripe.com/oauth/authorize?response_type=code&client_id=#{CGI.escape(client_id.to_s)}&scope=read_write&state=#{CGI.escape(state)}"
  end

  def organisation_from_stripe_connect_oauth_state(token, personal: false)
    data = TokenVerifier.verify(token)
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
    if personal
      TokenVerifier.generate("stripe_connect_personal:#{organisation.id}:#{current_account.id}")
    else
      TokenVerifier.generate("stripe_connect_org:#{organisation.id}")
    end
  end
end
