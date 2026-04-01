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

  def verify_and_set_atproto_credentials!
    return false unless atproto_connected?

    client = atproto_client
    did = client.did
    handle = client.session_handle
    return false unless did.present? && handle.present?

    set(atproto_did: did, atproto_handle: handle, atproto_app_password: atproto_app_password)
    true
  rescue StandardError
    false
  end

  def disconnect_atproto!
    set(atproto_handle: nil, atproto_app_password: nil, atproto_did: nil)
  end
end
