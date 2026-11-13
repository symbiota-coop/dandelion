module AccountNotifications
  extend ActiveSupport::Concern

  included do
    after_create :send_confirmation_email
    handle_asynchronously :send_first_event_email
  end

  # What an email greets someone by: %recipient.firstname%
  def greeting_name
    firstname || 'there'
  end

  # The recipient variables most emails send: %recipient.firstname%, the token their links sign in with, and the id
  def mail_variables
    { 'firstname' => greeting_name, 'token' => link_token_for_email, 'id' => id.to_s }
  end

  # This account as Mailer.deliver's to:, with any variables of the email's own
  def mail_recipient(extra_variables = {})
    [email, mail_variables.merge(extra_variables)]
  end

  def send_first_event_email
    account = self
    Mailer.deliver(
      to: [account.email, { 'firstname' => account.greeting_name }],
      from: ENV['FOUNDER_EMAIL_FULL'],
      reply_to: ENV['FOUNDER_EMAIL'],
      subject: 'Congratulations on listing your first event on Dandelion!',
      text: EmailHelper.render(:first_event)
    )
    account.set(sent_first_event_email: Time.now)
  end

  # Returns false, sending nothing, when this address has had RecipientLimit's number of codes this hour: the code in
  # the latest still works (SIGN_IN_CODE_LIFETIME)
  def send_sign_in_code
    return false unless RecipientLimit.allow?(:sign_in_code, email)

    account = self
    Mailer.deliver(
      :sign_in_code,
      to: [account.email, { 'firstname' => account.greeting_name, 'token' => account.issue_sign_in_code!, 'id' => account.id.to_s }],
      subject: 'Sign in code for Dandelion',
      microsoft_workaround: true
    )
    true
  end

  def send_confirmation_email
    return if skip_confirmation_email

    account = self
    Mailer.deliver(
      :confirm_email,
      to: account.mail_recipient('confirm_or_activate' => (account.has_signed_in? ? 'Click here to confirm your email address:' : "If you'd like to activate your account, click the link below:")),
      subject: 'Confirm your email address',
      microsoft_workaround: true
    )
  end

  def send_activation_notification
    Mailer.deliver(:activation_notification, to: self, subject: "You've activated your Dandelion account")
  end

  def send_stripe_subscription_created_notification(subscription)
    Mailer.deliver(
      to: Account.and(admin: true),
      subject: "[Account] #{name} created a subscription of #{subscription.plan.amount / 100} #{subscription.plan.currency.upcase} per month",
      text: "Account: #{ENV['BASE_URI']}/u/#{username}"
    )
  end

  def send_stripe_subscription_deleted_notification(subscription)
    Mailer.deliver(
      to: Account.and(admin: true),
      subject: "[Account] #{name} deleted a subscription of #{subscription.plan.amount / 100} #{subscription.plan.currency.upcase} per month",
      text: "Account: #{ENV['BASE_URI']}/u/#{username}"
    )
  end
end
