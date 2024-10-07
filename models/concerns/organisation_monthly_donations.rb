module OrganisationMonthlyDonations
  extend ActiveSupport::Concern

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
end
