class Organisation
  include Mongoid::Document
  include Mongoid::Timestamps
  extend Dragonfly::Model

  include OrganisationFields
  include OrganisationAssociations
  include OrganisationAccounting
  include OrganisationAccessControl
  include EvmTransactions
  include OrganisationEvm
  include OrganisationValidation
  include Geocoded

  def self.fs(slug)
    find_by(slug: slug)
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

  def ticket_email_greeting_default
    '<p>Hi [firstname],</p>
<p>Thanks for booking onto [event_name], [event_when] [at_event_location_if_not_online]. Your [tickets_are] attached.</p>'
  end

  def recording_email_greeting_default
    '<p>Hi [firstname],</p>
<p>Thanks for purchasing the recording of [event_name], [event_when] [at_event_location_if_not_online].</p>'
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

  def stripe_webhooks
    Stripe.api_key = stripe_sk
    Stripe.api_version = '2020-08-27'
    webhooks = []
    has_more = true
    starting_after = nil
    while has_more
      w = Stripe::WebhookEndpoint.list({ limit: 100, starting_after: starting_after })
      webhooks += w.data
      has_more = w.has_more
      starting_after = w.data.last.id
    end
    webhooks
  end

  after_save :create_stripe_webhook_if_necessary, if: :stripe_sk
  def create_stripe_webhook_if_necessary
    return unless Padrino.env == :production

    Stripe.api_key = stripe_sk
    Stripe.api_version = '2020-08-27'

    webhooks = []
    has_more = true
    starting_after = nil
    while has_more
      w = Stripe::WebhookEndpoint.list({ limit: 100, starting_after: starting_after })
      has_more = w['has_more']
      unless w['data'].empty?
        webhooks += w['data']
        starting_after = w['data'].last['id']
      end
    end

    return if webhooks.find { |w| w['url'] == "#{ENV['BASE_URI']}/o/#{slug}/stripe_webhook" && w['enabled_events'].include?('checkout.session.completed') }

    w = Stripe::WebhookEndpoint.create({
                                         url: "#{ENV['BASE_URI']}/o/#{slug}/stripe_webhook",
                                         enabled_events: [
                                           'checkout.session.completed'
                                         ]
                                       })
    update_attribute(:stripe_endpoint_secret, w['secret'])
  rescue Stripe::AuthenticationError
    update_attribute(:stripe_sk, nil)
    update_attribute(:stripe_pk, nil)
  end

  def sync_with_gocardless
    organisationships.and(monthly_donation_method: 'GoCardless').set(
      monthly_donation_method: nil,
      monthly_donation_amount: nil,
      monthly_donation_currency: nil,
      monthly_donation_start_date: nil
    )

    client = GoCardlessPro::Client.new(access_token: gocardless_access_token)

    list = client.subscriptions.list(params: { status: 'active' })
    subscriptions = list.records
    after = list.after
    while after
      list = client.subscriptions.list(params: { status: 'active', after: after })
      subscriptions += list.records
      after = list.after
    end

    subscriptions.each do |subscription|
      gocardless_subscribe(subscription: subscription)
    end
  end

  def gocardless_subscribe(subscription: nil, subscription_id: nil)
    client = GoCardlessPro::Client.new(access_token: gocardless_access_token)

    begin
      subscription = client.subscriptions.get(subscription_id) if subscription_id
    rescue GoCardlessPro::InvalidApiUsageError # to handle test webhooks
      return
    end
    return unless subscription.status == 'active'

    return if gocardless_filter && !subscription.name.include?(gocardless_filter)

    mandate = client.mandates.get(subscription.links.mandate)
    customer = client.customers.get(mandate.links.customer)

    name = "#{customer.given_name} #{customer.family_name}"
    email = customer.email
    postcode = customer.postal_code
    amount = subscription.amount
    currency = subscription.currency
    start_date = subscription.start_date
    puts "#{name} #{email} #{amount} #{currency} #{start_date}"

    account = Account.find_by(email: email.downcase) || Account.create(name: name, email: email)
    organisationship = organisationships.find_by(account: account) || organisationships.create(account: account)

    organisationship.monthly_donation_method = 'GoCardless'
    organisationship.monthly_donation_amount = amount.to_f / 100
    organisationship.monthly_donation_currency = currency
    organisationship.monthly_donation_start_date = start_date
    organisationship.monthly_donation_postcode = postcode
    organisationship.save
  end

  def sync_with_patreon
    organisationships.and(monthly_donation_method: 'Patreon').set(
      monthly_donation_method: nil,
      monthly_donation_amount: nil,
      monthly_donation_currency: nil,
      monthly_donation_start_date: nil
    )

    api_client = Patreon::API.new(patreon_api_key)

    # Get the campaign ID
    campaign_response = api_client.fetch_campaign
    campaign_id = campaign_response.data[0].id

    # Fetch all pledges
    all_pledges = []
    cursor = nil
    loop do
      page_response = api_client.fetch_page_of_pledges(campaign_id, { count: 25, cursor: cursor })
      all_pledges += page_response.data
      next_page_link = page_response.links[page_response.data]['next']
      break unless next_page_link

      parsed_query = CGI.parse(next_page_link)
      cursor = parsed_query['page[cursor]'][0]
    end

    all_pledges.each do |pledge|
      next unless pledge.declined_since.nil?

      name = pledge.patron.full_name
      email = pledge.patron.email
      amount = pledge.amount_cents
      currency = pledge.currency
      start_date = pledge.created_at

      puts "#{name} #{email} #{amount} #{currency} #{start_date}"
      account = Account.find_by(email: email.downcase) || Account.create(name: name, email: email)
      organisationship = organisationships.find_by(account: account) || organisationships.create(account: account)

      organisationship.monthly_donation_method = 'Patreon'
      organisationship.monthly_donation_amount = amount.to_f / 100
      organisationship.monthly_donation_currency = currency
      organisationship.monthly_donation_start_date = start_date
      organisationship.save
    end
  end

  def import_from_csv(csv)
    CSV.parse(csv, headers: true, header_converters: [:downcase, :symbol]).each do |row|
      email = row[:email]
      account_hash = { name: row[:name], email: row[:email], password: Account.generate_password }
      account = Account.new(account_hash) unless (account = Account.find_by(email: email.downcase))
      begin
        if account.persisted?
          account.update_attributes!(account_hash.map do |k, v|
                                       [k, v] if v
                                     end.compact.to_h)
        else
          account.save!
        end
        organisationships.create account: account, skip_welcome: row[:skip_welcome]
      rescue StandardError
        next
      end
    end
  end
  handle_asynchronously :import_from_csv

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
