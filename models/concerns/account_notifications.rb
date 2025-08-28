module AccountNotifications
  extend ActiveSupport::Concern

  included do
    after_create :send_confirmation_email
    handle_asynchronously :send_first_event_email
  end

  def send_first_event_email
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    account = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/first_event.erb'))).result(binding)
    batch_message.from ENV['FOUNDER_EMAIL_FULL']
    batch_message.reply_to ENV['FOUNDER_EMAIL']
    batch_message.subject 'Congratulations on listing your first event on Dandelion!'
    batch_message.body_text content

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there' })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    account.update_attribute(:sent_first_event_email, Time.now)
  end

  def send_sign_in_code
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    account = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/sign_in_code.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject 'Sign in code for Dandelion'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_confirmation_email
    return if skip_confirmation_email

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    account = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/confirm_email.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject 'Confirm your email address'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, {
                                    'firstname' => account.firstname || 'there',
                                    'token' => account.sign_in_token,
                                    'id' => account.id.to_s,
                                    'confirm_or_activate' => (account.sign_ins_count.zero? ? "If you'd like to activate your account, click the link below:" : 'Click here to confirm your email address:')
                                  })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_activation_notification
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    account = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/activation_notification.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "You've activated your Dandelion account"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_substack_invite(number = 3)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    account = self
    events = Event.past.and(:id.in => account.orders.and(:created_at.gt => 1.year.ago).pluck(:event_id)).order('start_time desc').limit(3)
    return unless events.count >= number

    content = ERB.new(File.read(Padrino.root('app/views/emails/substack_invite.erb'))).result(binding)
    batch_message.from 'Dandelion <stephen@dandelion.coop>'
    batch_message.subject 'Opt-in to our new Substack newsletter'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    update_attribute(:sent_substack_invite, Time.now)
  end

  def send_stripe_subscription_created_notification(subscription)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    account = self
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "[Account] #{account.name} created a subscription of #{subscription.plan.amount / 100} #{subscription.plan.currency.upcase} per month"
    batch_message.body_text "Account: #{ENV['BASE_URI']}/u/#{account.username}"

    Account.and(admin: true).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_stripe_subscription_deleted_notification(subscription)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    account = self
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "[Account] #{account.name} deleted a subscription of #{subscription.plan.amount / 100} #{subscription.plan.currency.upcase} per month"
    batch_message.body_text "Account: #{ENV['BASE_URI']}/u/#{account.username}"

    Account.and(admin: true).each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end

  def send_feedback_summary
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    account = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/feedback_summary.erb'))).result(binding)
    batch_message.from ENV['CONTACT_EMAIL_FULL']
    batch_message.subject 'New feedback summary from Dandelion'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
  end
end
