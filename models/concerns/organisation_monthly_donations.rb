module OrganisationMonthlyDonations
  extend ActiveSupport::Concern

  def sync_with_gocardless
    organisationships.and(monthly_donation_method: 'GoCardless').update_all(
      monthly_donation_amount: nil,
      monthly_donation_currency: nil,
      monthly_donation_start_date: nil,
      monthly_donation_annual: nil
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

    organisationships.and(monthly_donation_method: 'GoCardless', monthly_donation_amount: nil).each do |organisationship|
      send_finished_monthly_donor_notification(organisationship)
      organisationship.set(monthly_donation_method: nil)
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
    # puts "#{name} #{email} #{amount} #{currency} #{start_date}"

    account = Account.find_by(email: email.downcase) || Account.create(name: name, email: email)
    organisationship = organisationships.find_by(account: account) || organisationships.create(account: account)

    send_notification = organisationship.monthly_donation_method.nil?

    organisationship.monthly_donation_method = 'GoCardless'
    organisationship.monthly_donation_amount = amount.to_f / 100
    organisationship.monthly_donation_currency = currency
    organisationship.monthly_donation_start_date = start_date
    organisationship.monthly_donation_postcode = postcode
    organisationship.monthly_donation_annual = subscription.name =~ /\bannual\b/i ? true : false
    organisationship.monthly_donation_amount = (organisationship.monthly_donation_amount.to_f / 12).round(2) if organisationship.monthly_donation_annual

    organisationship.save

    send_new_monthly_donor_notification(organisationship) if send_notification
  end

  def sync_with_patreon
    organisationships.and(monthly_donation_method: 'Patreon').update_all(
      monthly_donation_amount: nil,
      monthly_donation_currency: nil,
      monthly_donation_start_date: nil,
      monthly_donation_annual: nil
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
      patreon_subscribe(pledge)
    end

    organisationships.and(monthly_donation_method: 'Patreon', monthly_donation_amount: nil).each do |organisationship|
      send_finished_monthly_donor_notification(organisationship)
      organisationship.set(monthly_donation_method: nil)
    end
  end

  def patreon_subscribe(pledge)
    return unless pledge.declined_since.nil?

    name = pledge.patron.full_name
    email = pledge.patron.email
    amount = pledge.amount_cents
    currency = pledge.currency
    start_date = pledge.created_at

    # puts "#{name} #{email} #{amount} #{currency} #{start_date}"
    account = Account.find_by(email: email.downcase) || Account.create(name: name, email: email)
    organisationship = organisationships.find_by(account: account) || organisationships.create(account: account)

    send_notification = organisationship.monthly_donation_method.nil?

    organisationship.monthly_donation_method = 'Patreon'
    organisationship.monthly_donation_amount = amount.to_f / 100
    organisationship.monthly_donation_currency = currency
    organisationship.monthly_donation_start_date = start_date
    organisationship.save

    send_new_monthly_donor_notification(organisationship) if send_notification
  end

  def send_new_monthly_donor_notification(organisationship)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    organisation = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/new_monthly_donor.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "New monthly donor for #{organisation.name}: #{organisationship.account.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    admins_receiving_feedback.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end

  def send_finished_monthly_donor_notification(organisationship)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    organisation = self
    content = ERB.new(File.read(Padrino.root('app/views/emails/finished_monthly_donor.erb'))).result(binding)
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Monthly donation ended for #{organisation.name}: #{organisationship.account.name}"
    batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

    admins_receiving_feedback.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
end
