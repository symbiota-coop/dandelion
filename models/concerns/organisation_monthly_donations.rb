module OrganisationMonthlyDonations
  extend ActiveSupport::Concern

  # Monthly donors come from GoCardless, or admins record them by hand, which organisations that already have
  # donors (such as those that synced them from Patreon) can go on doing
  def monthly_donations_enabled?
    (gocardless_subscriptions && gocardless_access_token) || monthly_donors_count.to_i.positive?
  end

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

    begin
      account = Account.find_by(email: email.downcase.strip) || Account.create!(name: name, email: email)
    rescue Mongoid::Errors::Validations => e
      ErrorReporting.capture_exception(e, context: { email: email, organisation_id: id.to_s, source: 'gocardless' })
      return
    end

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

  def send_new_monthly_donor_notification(organisationship)
    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    organisation = self
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "New monthly donor for #{organisation.name}: #{organisationship.account.name}"
    batch_message.body_html EmailHelper.html(:new_monthly_donor, organisationship: organisationship, organisation: organisation)

    admins_receiving_feedback.each do |account|
      batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.link_token_for_email, 'id' => account.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end

  def send_finished_monthly_donor_notification(organisationship)
    account = organisationship.account
    return unless account

    mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
    batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

    organisation = self
    batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
    batch_message.subject "Monthly donation ended for #{organisation.name}: #{account.name}"
    batch_message.body_html EmailHelper.html(:finished_monthly_donor, organisationship: organisationship, organisation: organisation)

    admins_receiving_feedback.each do |recipient|
      batch_message.add_recipient(:to, recipient.email, { 'firstname' => recipient.firstname || 'there', 'token' => recipient.link_token_for_email, 'id' => recipient.id.to_s })
    end

    batch_message.finalize if Padrino.env == :production
  end
end
