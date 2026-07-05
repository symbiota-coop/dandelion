Dandelion::App.helpers do
  def sign_in_via_token
    account = Account.find_by(sign_in_token: params[:sign_in_token].to_s)

    if account && !account.sign_in_token_expired?
      account.set(failed_sign_in_attempts: 0)
      account.sign_ins.create(request: request, skip_increment: %w[unsubscribe give_feedback subscriptions].any? { |p| request.path.include?(p) })
      if account.sign_ins_count == 1
        account.set(email_confirmed: true)
        account.send_activation_notification
      end
      session[:account_id] = account.id.to_s
      account.generate_sign_in_token!
      if (return_to = session.delete(:return_to))
        redirect return_to
      else
        flash.now[:notice] = 'Signed in via a code/link'
      end
    elsif !current_account
      kick! notice: "That sign in code/link isn't valid any longer. Please request a new one."
    end
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
