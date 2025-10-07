Dandelion::App.helpers do
  def sign_in_via_token
    account = Account.find_by(sign_in_token: params[:sign_in_token])

    if account && !account.sign_in_token_expired?
      flash.now[:notice] = 'Signed in via a code/link'
      account.update_attribute(:failed_sign_in_attempts, 0)
      account.sign_ins.create(env: env_yaml, skip_increment: %w[unsubscribe give_feedback subscriptions].any? { |p| request.path.include?(p) })
      if account.sign_ins_count == 1
        account.set(email_confirmed: true)
        account.send_activation_notification
      end
      session[:account_id] = account.id.to_s
      account.generate_sign_in_token
    elsif !current_account
      kick! notice: "That sign in code/link isn't valid any longer. Please request a new one."
    end
  end

  def sign_in_via_api_key
    if (account = Account.find_by(api_key: params[:api_key]))
      session[:account_id] = account.id.to_s
    elsif !current_account
      403
    end
  end
end
