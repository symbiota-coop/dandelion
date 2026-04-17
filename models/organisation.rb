class Organisation
  REFERRAL_REWARD_THRESHOLD = Money.new(100_00, 'EUR').freeze

  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  extend Dragonfly::Model
  include OrganisationFields
  include OrganisationAssociations
  include OrganisationAccounting
  include OrganisationAccessControl
  include OrganisationMonthlyDonations
  include OrganisationEvm
  include OrganisationValidation
  include OrganisationFeedbackSummaries
  include OrganisationAtproto
  include Geocoded
  include EvmTransactions
  include StripeWebhooks
  include ImportFromCsv
  include ImageWithValidation
  include Searchable

  def self.fs(slug)
    find_by(slug: slug)
  end

  def self.search_fields
    %w[name intro_text]
  end

  def self.search_scope
    self.and(hidden: false)
  end

  def self.protected_attributes
    %w[paid_up paid_up_fraction]
  end

  def to_param
    slug
  end

  def set_counts
    monthly_rows = organisationships.and(:monthly_donation_method.ne => nil).and(:monthly_donation_method.ne => 'Other').pluck(:monthly_donation_amount, :monthly_donation_currency)
    monthly_donations_count = monthly_rows.map do |amount, currency|
      next Money.new(0, 'GBP') if amount.nil? || currency.blank?

      Money.new(amount * 100, currency)
    end.sum
    monthly_donations_count = monthly_donations_count.format(no_cents: true) if monthly_donations_count > 0
    set(
      monthly_donations_count: monthly_donations_count,
      monthly_donors_count: monthly_donors.count,
      subscribed_accounts_count: subscribed_accounts.count,
      followers_count: organisationships.count
    )
  end

  def self.spring_clean
    fields = %i[image_uid]
    ignore = %i[organisationships notifications_as_notifiable]
    Organisation.all.each do |organisation|
      next unless Organisation.reflect_on_all_associations(:has_many).all? do |assoc|
        organisation.send(assoc.name).empty? || ignore.include?(assoc.name)
      end && fields.all? { |f| organisation.send(f).blank? } && organisation.created_at < 1.month.ago

      puts organisation.name
      # organisation.destroy
    end
  end

  def self.currencies
    CURRENCY_OPTIONS
  end

  def self.lead
    find_by(slug: ENV['LEAD_ORG_SLUG'])
  end

  def free_mailgun?(excluding_pmail: nil)
    pmails_scope = pmails.and(:mailable_type.ne => 'Event', :requested_send_at.gte => 1.month.ago)
    pmails_scope = pmails_scope.and(:id.ne => excluding_pmail.id) if excluding_pmail
    organisationships.count <= ENV['MAILGUN_FREE_SUBSCRIBER_LIMIT'].to_i && !pmails_scope.exists?
  end

  def mailgun_enabled?
    mailgun_api_key || free_mailgun?
  end

  def banned_emails_a
    banned_emails ? banned_emails.split("\n").map(&:strip) : []
  end

  def calendar_import_urls_a
    calendar_import_urls ? calendar_import_urls.split("\n").map(&:strip).reject(&:blank?) : []
  end

  def calendar_import_feeds_in_url_order
    names = (calendar_import_feed_calendar_names || {}).stringify_keys
    seen = {}
    calendar_import_urls_a.filter_map do |line|
      url = CalendarImportSync.normalize_feed_url(line)
      next if seen[url]

      seen[url] = true
      n = names[url]
      [url, n] if n.present?
    rescue CalendarImportSync::ConfigurationError
      nil
    end
  end

  after_create do
    notifications_as_notifiable.create! circle: account, type: 'created_organisation'

    organisationships.create account: account, admin: true, receive_feedback: true
    if (dandelion = Organisation.find_by(slug: 'dandelion'))
      dandelion.organisationships.create account: account
    end
  end

  after_save do
    events.each(&:set_browsable) if saved_change_to_hidden? || saved_change_to_paid_up?
  end

  def stripe_webhook_url
    "#{ENV['BASE_URI']}/o/#{slug}/stripe_webhook"
  end

  def sync_calendar_imports
    names_by_feed = (calendar_import_feed_calendar_names || {}).stringify_keys
    normalized_feed_urls = calendar_import_urls_a.filter_map do |u|
      CalendarImportSync.normalize_feed_url(u)
    rescue CalendarImportSync::ConfigurationError
      nil
    end

    results = calendar_import_urls_a.map { |feed_url| CalendarImportSync.new(self, feed_url: feed_url).sync }
    errors = results.filter_map { |result| "#{result[:feed_url]}: #{result[:error]}" if result[:error] }

    results.each do |result|
      next if result[:error].present?
      next if result[:calendar_name].blank?

      names_by_feed[result[:feed_url].to_s] = result[:calendar_name]
    end
    names_by_feed.keep_if { |url, _| normalized_feed_urls.include?(url) }

    set(
      calendar_import_last_synced_at: Time.now,
      calendar_import_last_sync_error: errors.any? ? errors.join("\n") : nil,
      calendar_import_feed_calendar_names: names_by_feed
    )

    {
      created: results.sum { |result| result[:created] || 0 },
      updated: results.sum { |result| result[:updated] || 0 },
      skipped: results.sum { |result| result[:skipped] || 0 },
      feeds: results,
      errors: errors
    }
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
    'Reminder about [event_name]'
  end

  def reminder_email_body_default
    %{<p>Hi [firstname],</p>
  <p>Just a reminder that [event_link] is coming up soon.</p>
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

  def payment_method?
    EventPaymentMethod.all.any? { |pm| pm.org_condition&.call(self) }
  end

  def stripe_connect_only?
    return false unless stripe_connect_json
    return false if stripe_pk

    EventPaymentMethod.all.none? do |pm|
      pm.name != 'stripe' && pm.org_condition&.call(self)
    end
  end

  def referral_revenue
    target_currency = REFERRAL_REWARD_THRESHOLD.currency
    to_target = lambda { |amount, currency|
      begin
        Money.new((amount || 0) * 100, currency).exchange_to(target_currency).cents
      rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
        0
      end
    }

    event_ids = events.pluck(:id)
    cents = Donation.and(:event_id.in => event_ids, payment_completed: true, application_fee_paid_to_dandelion: true).sum { |d| to_target.call(d.amount, d.currency) }
    cents += organisation_contributions.and(payment_completed: true).sum { |oc| to_target.call(oc.amount, oc.currency) }
    Money.new(cents, target_currency)
  end

  def donations_to_dandelion?
    stripe_connect_only? && !paid_up
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

    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject 'Dandelion CSV export'
    batch_message.body_html EmailHelper.html(:csv)

    file = Tempfile.new
    file.write(csv)
    file.rewind
    batch_message.add_attachment(file.path, 'followers.csv')

    batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })

    batch_message.finalize if Padrino.env == :production
    file.close
    file.unlink
  end
  handle_asynchronously :send_followers_csv
end
