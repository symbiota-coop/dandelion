module OrganisationAtproto
  extend ActiveSupport::Concern

  def atproto_connected?
    atproto_handle.present? && atproto_app_password.present?
  end

  def atproto_client
    return nil unless atproto_connected?

    AtprotoClient.new(handle: atproto_handle, app_password: atproto_app_password)
  end

  def atproto_profile_url
    return nil unless atproto_handle.present?

    "https://bsky.app/profile/#{atproto_handle}"
  end

  def verify_atproto_credentials!
    return false unless atproto_connected?

    session = atproto_client.create_session
    return false unless session

    set(atproto_did: session['did']) if session['did']
    set(atproto_handle: session['handle']) if session['handle']
    true
  rescue StandardError
    false
  end

  def disconnect_atproto!
    set(atproto_handle: nil, atproto_app_password: nil, atproto_did: nil)
  end
end
