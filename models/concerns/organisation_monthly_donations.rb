module OrganisationMonthlyDonations
  extend ActiveSupport::Concern

  PATREON_API = 'https://www.patreon.com/api/oauth2'
  # Pledge events that set what a patron pays. Charges (subscription) and cancellations (pledge_delete) don't
  PATREON_PLEDGE_EVENT_TYPES = %w[pledge_start pledge_upgrade pledge_downgrade].freeze

  # Monthly donors come from GoCardless or Patreon, or admins record them by hand, which organisations that already
  # have donors can go on doing
  def monthly_donations_enabled?
    (gocardless_subscriptions && gocardless_access_token) || patreon_refresh_token || monthly_donors_count.to_i.positive?
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

  def patreon_connection
    Faraday.new(url: PATREON_API) do |f|
      f.request :url_encoded
      f.response :raise_error
      f.response :json
    end
  end

  # Patreon's creator tokens last a month, and each refresh replaces the refresh token too, so every sync swaps it
  # for a new pair and saves the new refresh token straight away
  def patreon_access_token!
    response = patreon_connection.post('token', grant_type: 'refresh_token', refresh_token: patreon_refresh_token,
                                                client_id: patreon_client_id, client_secret: patreon_client_secret)
    set(patreon_refresh_token: response.body['refresh_token'])
    response.body['access_token']
  end

  # Active patrons, as [email, name, amount, currency, start date, annual]
  def patreon_patrons
    conn = patreon_connection
    conn.headers['Authorization'] = "Bearer #{patreon_access_token!}"

    campaign = conn.get('v2/campaigns', 'fields[campaign]' => 'currency').body['data'].first
    return [] unless campaign

    patrons = []
    params = {
      'include' => 'pledge_history',
      'fields[member]' => 'email,full_name,patron_status,pledge_relationship_start,pledge_cadence,currently_entitled_amount_cents',
      'fields[pledge-event]' => 'amount_cents,currency_code,date,type',
      'page[count]' => 500
    }
    loop do
      body = conn.get("v2/campaigns/#{campaign['id']}/members", params).body
      pledge_events = (body['included'] || []).select { |r| r['type'] == 'pledge-event' }.index_by { |r| r['id'] }
      body['data'].each do |member|
        attributes = member['attributes']
        next unless attributes['patron_status'] == 'active_patron' && attributes['email']

        # The member's amounts are in the campaign's currency; their latest pledge event has what they pay, in
        # their own currency
        pledge = (member.dig('relationships', 'pledge_history', 'data') || []).filter_map { |r| pledge_events[r['id']]&.dig('attributes') }
                                                                             .select { |e| PATREON_PLEDGE_EVENT_TYPES.include?(e['type']) && e['amount_cents'] }
                                                                             .max_by { |e| e['date'] }
        amount, currency = pledge ? [pledge['amount_cents'], pledge['currency_code']] : [attributes['currently_entitled_amount_cents'], campaign['attributes']['currency']]
        next unless amount&.positive? && currency

        cadence = [attributes['pledge_cadence'].to_i, 1].max
        start_date = (Date.parse(attributes['pledge_relationship_start']) if attributes['pledge_relationship_start'])
        patrons << [attributes['email'], attributes['full_name'], (amount.to_f / 100 / cadence).round(2), currency, start_date, cadence == 12]
      end
      cursor = body.dig('meta', 'pagination', 'cursors', 'next')
      break unless cursor

      params['page[cursor]'] = cursor
    end
    patrons
  end

  def sync_with_patreon
    begin
      patrons = patreon_patrons
    rescue Faraday::Error => e
      set(patreon_sync_error: e.is_a?(Faraday::UnauthorizedError) || e.is_a?(Faraday::BadRequestError) ? 'Patreon rejected the client or refresh token: paste a new Creator\'s Refresh Token' : e.message)
      ErrorReporting.capture_exception(e, context: { organisation_id: id.to_s, source: 'patreon' })
      return
    end
    set(patreon_sync_error: nil)

    organisationships.and(monthly_donation_method: 'Patreon').update_all(
      monthly_donation_amount: nil,
      monthly_donation_currency: nil,
      monthly_donation_start_date: nil,
      monthly_donation_annual: nil
    )

    patrons.each do |email, name, amount, currency, start_date, annual|
      patreon_subscribe(email: email, name: name, amount: amount, currency: currency, start_date: start_date, annual: annual)
    end

    organisationships.and(monthly_donation_method: 'Patreon', monthly_donation_amount: nil).each do |organisationship|
      send_finished_monthly_donor_notification(organisationship)
      organisationship.set(monthly_donation_method: nil)
    end
  end

  def patreon_subscribe(email:, name:, amount:, currency:, start_date:, annual:)
    begin
      account = Account.find_by(email: email.downcase.strip) || Account.create!(name: name, email: email)
    rescue Mongoid::Errors::Validations => e
      ErrorReporting.capture_exception(e, context: { email: email, organisation_id: id.to_s, source: 'patreon' })
      return
    end

    organisationship = organisationships.find_by(account: account) || organisationships.create(account: account)

    send_notification = organisationship.monthly_donation_method.nil?

    organisationship.monthly_donation_method = 'Patreon'
    organisationship.monthly_donation_amount = amount
    organisationship.monthly_donation_currency = currency
    organisationship.monthly_donation_start_date = start_date
    organisationship.monthly_donation_annual = annual
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
