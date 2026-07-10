Dandelion::App.helpers do
  def stripe_connect_oauth_url(organisation:, client_id:)
    state = SecureRandom.hex(32)
    session[:stripe_connect_state] = state
    session[:stripe_connect_organisation_id] = organisation.id.to_s
    "https://connect.stripe.com/oauth/authorize?response_type=code&client_id=#{CGI.escape(client_id.to_s)}&scope=read_write&state=#{state}"
  end

  def valid_stripe_connect_oauth_state?(organisation)
    state = session.delete(:stripe_connect_state)
    organisation_id = session.delete(:stripe_connect_organisation_id)
    return false unless state.is_a?(String) && params[:state].is_a?(String)
    return false unless state.bytesize == params[:state].bytesize
    return false unless organisation_id == organisation.id.to_s

    ActiveSupport::SecurityUtils.secure_compare(state, params[:state])
  end
end
