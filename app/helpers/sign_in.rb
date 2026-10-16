Dandelion::App.helpers do
  # A link in an email, which works until it expires, for anyone the email reaches
  def sign_in_via_link_token
    token = link_token_param.to_s
    # Accounts the rename from sign_in_token hasn't reached yet have it under the old name: drop this once it has run
    account = Account.find_by(link_token: token) || Account.and(sign_in_token: token).first

    if account && !Account.link_token_expired?(token)
      sign_in_from_email(account)
    elsif !current_account
      kick! notice: "That sign in link isn't valid any longer. Please sign in again."
    end
  end

  # A sign in code the person asked for, which works once and lets the session change the account's
  # email, password and providers (recently_verified?)
  def sign_in_via_code
    code = params[:sign_in_code].to_s

    if (account = Account.with_sign_in_code(code))
      sign_in_from_email(account, sign_in_code: code)
    elsif current_account
      flash.now[:error] = "That sign in code isn't valid any longer. Please request a new one."
    else
      kick! notice: "That sign in code isn't valid any longer. Please request a new one."
    end
  end

  def sign_in_from_email(account, sign_in_code: nil)
    # Block switching only when the session still belongs to a different live account. Look it up afresh
    # (not the memoized current_account) so a deleted account or a revoked session can't block it
    session_owner = session_account
    return if session_owner && session_owner != account

    kick! notice: "That sign in code isn't valid any longer. Please request a new one." if sign_in_code && !account.redeem_sign_in_code!(sign_in_code)

    account.set(failed_sign_in_attempts: 0)
    account.sign_ins.create(request: request, skip_increment: %w[unsubscribe give_feedback subscriptions].any? { |p| request.path.include?(p) })
    start_session!(account, verified: !sign_in_code.nil?)
    @signed_in_via_email = true
    account.generate_link_token!
    if account.sign_ins_count == 1
      account.set(email_confirmed: true)
      account.send_activation_notification
    end
    if sign_in_landing_path? && (return_to = session.delete(:return_to))
      redirect return_to
    else
      session.delete(:return_to)
      flash.now[:notice] = sign_in_code ? 'Signed in with a sign in code' : 'Signed in via a link'
    end
  end

  # Every sign in goes through here. verified: signed in with a sign in code (recently_verified?)
  def start_session!(account, verified: false)
    session.delete(:verified_at) unless verified || session[:account_id] == account.id.to_s
    session[:account_id] = account.id.to_s
    session[:session_token] = account.session_token!
    session[:verified_at] = Time.now.to_i if verified
    @current_account = account
  end

  # The session's account, while the session carries the account's session_token (revoke_sessions! changes it).
  # Sessions from before session tokens are given one, unless the account has since revoked its sessions
  def session_account
    return unless session[:account_id]

    account = Account.find(session[:account_id])
    if account && session[:session_token]
      return account if account.session_token && ActiveSupport::SecurityUtils.secure_compare(session[:session_token].to_s, account.session_token)
    elsif account && !account.legacy_sessions_revoked?
      token = account.session_token!
      # A revocation since the account was read sets a new token and legacy_sessions_revoked together: don't adopt that token
      unless Account.and(id: account.id, legacy_sessions_revoked: true).exists?
        session[:session_token] = token
        return account
      end
    end

    %i[account_id session_token verified_at].each { |k| session.delete(k) }
    nil
  end

  # Within the last hour, this session signed in with a sign in code sent to the account's email
  def recently_verified?
    current_account && session[:verified_at] && session[:verified_at].to_i > 1.hour.ago.to_i
  end

  # Changing the account's email, password or providers needs recently_verified?, so a session from a link in a
  # forwarded email can't take the account over. Sends a code and comes back
  def verification_required!(return_to:, notice:)
    return if recently_verified?

    current_account.send_sign_in_code
    session[:return_to] = return_to
    flash[:notice] = "We've emailed you a sign in code to confirm it's you. #{notice}"
    redirect "/accounts/sign_in_code?account_id=#{current_account.id}"
  end

  # Links in emails sent before the rename, and in emails organisers have saved, say sign_in_token
  def link_token_param
    params[:link_token] || params[:sign_in_token]
  end

  def sign_in_landing_path?
    ['/', '/accounts/sign_in', '/accounts/sign_in_code'].include?(request.path)
  end

  def sign_in_via_api_key
    if (account = Account.find_by(api_key: params[:api_key].to_s))
      @current_account_via_api_key = account
    elsif !current_account
      halt 403
    end
  end

  def sign_in_via_ics_key
    return unless params[:ics_key]

    if (account = Account.find_by(ics_key: params[:ics_key].to_s))
      @current_account_via_ics_key = account
    elsif !current_account
      halt 403
    end
  end
end
