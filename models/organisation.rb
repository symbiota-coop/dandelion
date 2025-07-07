class Organisation
  include Mongoid::Document
  include Mongoid::Timestamps
  include BelongsToWithoutParentValidation

  extend Dragonfly::Model
  include OrganisationFields
  include OrganisationAssociations
  include OrganisationAccounting
  include OrganisationAccessControl
  include OrganisationMonthlyDonations
  include OrganisationEvm
  include OrganisationValidation
  include OrganisationFeedbackSummaries
  include Geocoded
  include EvmTransactions
  include StripeWebhooks
  include ImportFromCsv
  include ImageWithValidation

  def self.fs(slug)
    find_by(slug: slug)
  end

  def self.set_counts
    Organisation.all.each do |organisation|
      monthly_donations_count = organisation.organisationships.and(:monthly_donation_method.ne => nil).and(:monthly_donation_method.ne => 'Other').map do |organisationship|
        Money.new(
          organisationship.monthly_donation_amount * 100,
          organisationship.monthly_donation_currency
        )
      end.sum
      monthly_donations_count = monthly_donations_count.format(no_cents: true) if monthly_donations_count > 0
      organisation.set(monthly_donations_count: monthly_donations_count)
      organisation.set(monthly_donors_count: organisation.monthly_donors.count)

      organisation.update_paid_up_without_delay
      if organisation.stripe_customer_id
        cr = organisation.contribution_requested
        cp = organisation.contribution_paid
        organisation.stripe_topup if cp < (Organisation.paid_up_fraction * cr)
      end

      organisation.set(subscribed_accounts_count: organisation.subscribed_accounts.count)
      organisation.set(followers_count: organisation.organisationships.count)
    end
  end

  def self.spring_clean
    fields = %i[image_uid]
    ignore = %i[organisationships notifications_as_notifiable]
    Organisation.all.each do |organisation|
      next unless Organisation.reflect_on_all_associations(:has_many).all? do |assoc|
        organisation.send(assoc.name).count == 0 || ignore.include?(assoc.name)
      end && fields.all? { |f| organisation.send(f).blank? } && organisation.created_at < 1.month.ago

      puts organisation.name
      organisation.destroy
    end
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def calculate_tokens
    Order.and(:event_id.in => events.pluck(:id), :value.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |o| Math.sqrt(Money.new(o.value * 100, o.currency).exchange_to('GBP').cents) } +
      organisation_contributions.and(:amount.ne => nil, :currency.in => MAJOR_CURRENCIES).sum { |p| Math.sqrt(Money.new(p.amount * 100, p.currency).exchange_to('GBP').cents) }
  end

  def banned_emails_a
    banned_emails ? banned_emails.split("\n").map(&:strip) : []
  end

  def payment_method?
    stripe_connect_json || stripe_pk || coinbase_api_key || evm_address || oc_slug
  end

  after_create do
    notifications_as_notifiable.create! circle: account, type: 'created_organisation'

    organisationships.create account: account, admin: true, receive_feedback: true
    if (dandelion = Organisation.find_by(slug: 'dandelion'))
      dandelion.organisationships.create account: account
    end
  end

  after_save do
    events.each(&:set_browsable) if hidden_changed? || paid_up_changed?
  end

  def stripe_webhook_url
    "#{ENV['BASE_URI']}/o/#{slug}/stripe_webhook"
  end

  def ticket_email_title_default
    '[ticket_or_tickets] to [event_name]'
  end

  def ticket_email_greeting_default
    '<p>Hi [firstname],</p>
<p>Thanks for booking onto [event_name], [event_when] [at_event_location_if_not_online]. Your [tickets_are] attached.</p>'
  end

  def recording_email_title_default
    'Recording of [event_name]'
  end

  def recording_email_greeting_default
    '<p>Hi [firstname],</p>
<p>Thanks for purchasing the recording of [event_name], [event_when] [at_event_location_if_not_online].</p>'
  end

  def reminder_email_title_default
    '[event_name] is tomorrow'
  end

  def reminder_email_body_default
    %{<p>Hi [firstname],</p>
  <p>Just a reminder that [event_link] is tomorrow.</p>
  <p>
    You should have received a confirmation email with your ticket(s) shortly after purchase. (If you don't see anything in your inbox, please look in your spam folder.)
  </p>
  [key_information_again]}
  end

  def feedback_email_title_default
    'Feedback on [event_name]'
  end

  def feedback_email_body_default
    '<p>Hi [firstname],</p>
<p>Thanks for attending [event_name].</p>
<p>Would you take a minute to <a href="[feedback_url]">visit this page and give us feedback on the event</a>, so that we can keep improving?</p>
<p>With thanks,<br>[organisation_name]</p>'
  end

  def donations_to_dandelion?
    stripe_connect_json && !paid_up
  end

  def stripe_user_id
    return unless stripe_connect_json

    JSON.parse(stripe_connect_json)['stripe_user_id']
  end

  def stripe_account_name
    return unless stripe_account_json

    j = JSON.parse(stripe_account_json)
    j.dig('business_profile', 'name') ||
      j.dig('settings', 'dashboard', 'display_name') ||
      j['display_name']
  end

  def send_followers_csv(account)
    csv = CSV.generate do |csv|
      csv << %w[name firstname lastname email unsubscribed created_at monthly_donation_method monthly_donation_amount monthly_donation_currency monthly_donation_start_date]
      organisationships.each do |organisationship|
        csv << [
          organisationship.account.name,
          organisationship.account.firstname,
          organisationship.account.lastname,
          Organisation.admin?(self, account) ? organisationship.account.email : '',
          (1 if organisationship.unsubscribed),
          organisationship.created_at.to_fs(:db_local),
          organisationship.monthly_donation_method,
          organisationship.monthly_donation_amount,
          organisationship.monthly_donation_currency,
          organisationship.monthly_donation_start_date
        ]
      end
    end

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    content = ERB.new(File.read(Padrino.root('app/views/emails/csv.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject 'Dandelion CSV export'
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    file = Tempfile.new
    file.write(csv)
    file.rewind
    batch_message.add_attachment(file.path, 'followers.csv')

    [account].each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if ENV['MAILGUN_API_KEY']
    file.close
    file.unlink
  end
  handle_asynchronously :send_followers_csv
end
