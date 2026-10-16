Dandelion::App.helpers do
  # A link in an email, which works until it expires, for anyone the email reaches
  def sign_in_via_link_token
    token = link_token_param.to_s
    account = Account.find_by(link_token: token)

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
    # Only a code confirms the email here: anyone the email reaches, mail scanners included, can open a link
    undone = confirm_email_of(account, same_browser: account_set_up_in_this_session?(account)) if sign_in_code && !account.email_confirmed?
    start_session!(account, verified: !sign_in_code.nil?, via_link: sign_in_code.nil?)
    @signed_in_via_email = true
    account.generate_link_token!
    account.send_activation_notification if account.sign_ins_count == 1
    notice = [sign_in_code ? 'Signed in with a sign in code' : 'Signed in via a link', undone].compact.join('. ')
    if sign_in_landing_path? && (return_to = session.delete(:return_to))
      flash[:notice] = notice if undone
      redirect return_to
    else
      session.delete(:return_to)
      flash.now[:notice] = notice
    end
  end

  # Every sign in goes through here. verified: signed in with a sign in code (recently_verified?).
  # via_link: signed in with a link in an email, which anyone the email reaches can open, so unlike signing up, a password,
  # a provider or a code, it doesn't mark the session as one that set the account up (account_set_up_in_this_session?)
  def start_session!(account, verified: false, via_link: false)
    # Restarting the account's own session (after revoke_sessions!, say) keeps what it was started with
    unless session[:account_id] == account.id.to_s
      session.delete(:verified_at) unless verified
      if via_link
        session.delete(:set_up_account)
      else
        session[:set_up_account] = true
      end
    end
    session[:account_id] = account.id.to_s
    session[:session_token] = account.session_token!
    session[:verified_at] = Time.now.to_i if verified
    @current_account = account
  end

  # This session is the account's, and was started by signing up, a password, a provider or a code, not by an emailed link:
  # whoever set the account up, and whoever confirms its email here, are the same person. Sessions from before the
  # marker don't have it, as they could have come from links
  def account_set_up_in_this_session?(account)
    session_account == account && session[:set_up_account] == true
  end

  # Confirms the account's email (Account#confirm_email!), and returns what to tell the person about anything it undid
  def confirm_email_of(account, same_browser:)
    removed_providers = account.confirm_email!(same_browser: same_browser)
    return if same_browser

    notice = 'Your email address was confirmed. It was confirmed in a different browser from the one that set this account up, so we signed out other browsers and reset its password'
    if removed_providers.any?
      them = removed_providers.one? ? 'it' : 'them'
      notice += ". #{removed_providers.to_sentence} had been connected to this account before its email address was confirmed, so we disconnected #{them}. If that was you, connect #{them} again from your account settings"
    end
    "#{notice}."
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

    %i[account_id session_token verified_at set_up_account].each { |k| session.delete(k) }
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
