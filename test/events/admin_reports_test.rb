require_relative '../test_config'

# What an event's admins see of its money (the Stripe report, its Stripe charges and donations), its private notes,
# its email previews and resending its feedback emails, and that nobody else can see or do them
class EventAdminReportsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # A charge as Stripe's search gives it, with its balance transaction expanded, in cents of currency
  def stripe_report_charge(id:, amount:, fee:, name:, email:, order: nil, application_fee: 0, application_fee_id: nil, refunded: 0, disputed: false, created: Time.utc(2026, 10, 1, 12))
    fee_details = [{ type: 'stripe_fee', amount: fee }]
    fee_details << { type: 'application_fee', amount: application_fee } if application_fee.positive?
    Stripe::Charge.construct_from(
      id: id, object: 'charge', status: 'succeeded', amount: amount, amount_refunded: refunded, payment_intent: "pi_#{id}",
      livemode: false, created: created.to_i, disputed: disputed, application_fee: application_fee_id,
      metadata: { de_account_name: name, de_account_email: email, de_order_id: order&.id&.to_s }.compact,
      balance_transaction: { id: "txn_#{id}", object: 'balance_transaction', amount: amount, currency: 'eur', exchange_rate: nil, fee_details: fee_details }
    )
  end

  # Stripe's search for the event's charges finds these while the block runs, and the queries it was given are kept
  def with_stripe_report_charges(charges, application_fees_refunded: {})
    queries = []
    results = Struct.new(:charges) { def auto_paging_each(&) = charges.each(&) }.new(charges)
    Stripe::Charge.stub(:search, lambda { |params, _opts|
      queries << params[:query]
      results
    }) do
      Stripe::ApplicationFee.stub(:retrieve, ->(id, _opts) { api_object(amount_refunded: application_fees_refunded.fetch(id)) }) do
        yield queries
      end
    end
  end

  def connect_organisation_to_stripe
    @organisation.set(stripe_connect_json: { stripe_user_id: 'acct_test' }.to_json)
  end

  # The cells of each row of the table
  def table_rows(table)
    table = find(table) if table.is_a?(String)
    table.all('tbody tr').map { |row| row.all('td').map { |cell| cell.text.squish } }
  end

  def admin_of_another_event
    other_organisation = FactoryBot.create(:organisation)
    FactoryBot.create(:event, organisation: other_organisation)
    other_organisation.account
  end

  # Stripe report

  test 'the Stripe report shows the totals and each charge as Stripe has them, in the currency Stripe pays out in' do
    create_event(prices: [30], currency: 'EUR')
    connect_organisation_to_stripe
    buyer = FactoryBot.create(:account, name: 'Bea Buyer')
    order = @event.orders.create!(account: buyer, currency: 'EUR', value: 30, payment_completed: true)
    charges = [
      stripe_report_charge(id: 'ch_paid', amount: 3000, fee: 120, application_fee: 300, name: 'Bea Buyer', email: buyer.email, order: order),
      # Refunded in full, with its donation to Dandelion
      stripe_report_charge(id: 'ch_refunded', amount: 2000, fee: 88, application_fee: 200, application_fee_id: 'fee_refunded', refunded: 2000,
                           name: 'Rae Funded', email: 'rae@example.com', created: Time.utc(2026, 9, 1, 12))
    ]

    with_stripe_report_charges(charges, application_fees_refunded: { 'fee_refunded' => 200 }) do |queries|
      sign_in(@account)
      visit "/e/#{@event.slug}/stripe_report"
      assert page.has_css?('#stripe-report-charges tbody tr', count: 2)
      assert_equal ["metadata['de_event_id']:'#{@event.id}'"], queries.uniq

      # Charges, gross, refunded, donations to Dandelion, revenue, Stripe fees, net
      assert_equal [['2', '€50', '€20', '€3', '€27', '€2,08', '€24,92']], table_rows(find(:xpath, "//table[thead/tr/th[normalize-space()='Charges']]"))
      # Newest first: customer, gross, refunded, donation to Dandelion, revenue, Stripe fees, net
      charge_rows = table_rows('#stripe-report-charges').map { |row| row.drop(1) }
      assert_equal [
        ["Bea Buyer #{buyer.email}", '€30', '', '€3', '€27', '€1,20', '€25,80', ''],
        ['Rae Funded rae@example.com', '€20', '€20', '', '€0', '€0,88', '€-0,88', '']
      ], charge_rows
      assert page.has_link?('Bea Buyer', href: "/e/#{@event.slug}/orders?q=#{CGI.escape(buyer.email)}")
    end
  end

  test 'the Stripe report is refused to event admins who are not revenue admins, other events admins and people signed out' do
    create_event(prices: [30], currency: 'EUR')
    connect_organisation_to_stripe
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    charges = [stripe_report_charge(id: 'ch_paid', amount: 3000, fee: 120, name: 'Secret Buyer', email: 'secret-buyer@example.com')]

    with_stripe_report_charges(charges) do |queries|
      [facilitator, admin_of_another_event, nil].each do |account|
        account ? sign_in_with_rack(account) : clear_cookies
        get "/e/#{@event.slug}/stripe_report"
        assert last_response.redirect?, account&.email
        assert_equal "/e/#{@event.slug}", URI(last_response.location).path
        refute_includes last_response.body, 'Secret Buyer'
      end
      assert_empty queries

      sign_in_with_rack(@account)
      get "/e/#{@event.slug}/stripe_report"
      assert last_response.ok?
    end
  end

  # Stripe charges

  test 'an event admin sees the event’s Stripe charges with their amounts, fees and refunds, in its currency' do
    create_event(prices: [30], currency: 'EUR')
    buyer = FactoryBot.create(:account, name: 'Bea Buyer')
    order = @event.orders.create!(account: buyer, currency: 'EUR', value: 30, payment_completed: true)
    charge_attributes = { event: @event, currency: 'EUR', balance_transaction: 'txn_test', created: Time.utc(2026, 10, 1, 12) }
    @organisation.stripe_charges.create!(id: 'ch_shared', account: buyer, order: order, amount: 3000, application_fee_amount: 2500, balance_float: 25,
                                         description: "#{@event.name}: 1 ticket", **charge_attributes)
    @organisation.stripe_charges.create!(id: 'ch_refunded', account: buyer, amount: 1000, balance_float: 0, description: "#{@event.name}: Donation",
                                         **charge_attributes, created: Time.utc(2026, 9, 2))
    @organisation.stripe_charges.create!(id: 'ch_partly_refunded', account: buyer, amount: 2000, balance_float: 10, description: "#{@event.name}: 2 tickets",
                                         **charge_attributes, created: Time.utc(2026, 9, 1))
    # Not yet settled, and another event's
    @organisation.stripe_charges.create!(id: 'ch_unsettled', account: buyer, amount: 4000, description: 'Unsettled', **charge_attributes, balance_transaction: nil)
    @organisation.stripe_charges.create!(id: 'ch_other_event', account: buyer, amount: 5000, description: 'Other event', **charge_attributes,
                                         event: FactoryBot.create(:event, organisation: @organisation))

    sign_in(@account)
    visit "/e/#{@event.slug}/stripe_charges"
    assert page.has_css?('#stripe-charges tbody tr', count: 3)

    rows = table_rows('#stripe-charges')
    # Charge ID, description, original amount, paid to revenue sharer, application fee, balance
    amounts = rows.map { |row| row.values_at(1..6) }
    assert_equal [
      ['ch_shared', '1 ticket', '€30', '€5', '€25', '€25'],
      ['ch_refunded', 'Donation', '€10', '', '', '€0 Refunded'],
      ['ch_partly_refunded', '2 tickets', '€20', '', '', '€10 Partial refund']
    ], amounts
    assert_includes rows.first.first, 'Bea Buyer'
    assert_includes rows.first[7], 'Bea Buyer on'
    assert page.has_no_content?('ch_unsettled')
    assert page.has_no_content?('ch_other_event')
  end

  test 'the Stripe charges and donations are refused to other events admins, attendees and people signed out' do
    create_event(prices: [30], currency: 'EUR')
    buyer = FactoryBot.create(:account, name: 'Secret Buyer')
    order = @event.orders.create!(account: buyer, currency: 'EUR', value: 30, payment_completed: true)
    @event.tickets.create!(account: buyer, order: order, ticket_type: @event.ticket_types.first, payment_completed: true)
    @event.donations.create!(account: buyer, order: order, amount: 5, payment_completed: true)
    @organisation.stripe_charges.create!(id: 'ch_secret', event: @event, account: buyer, order: order, amount: 3000, currency: 'EUR',
                                         balance_transaction: 'txn_test', created: Time.now, description: 'Secret charge')

    [admin_of_another_event, buyer, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      %w[stripe_charges donations].each do |path|
        get "/e/#{@event.slug}/#{path}"
        assert last_response.redirect?, "#{path} #{account&.email}"
        assert_equal "/e/#{@event.slug}", URI(last_response.location).path
        refute_includes last_response.body, 'Secret Buyer'
        refute_includes last_response.body, 'ch_secret'
      end
    end
  end

  # Donations

  test 'an event admin sees the event’s donations, with what reached them in its currency' do
    create_event(prices: [30], currency: 'EUR')
    donor = FactoryBot.create(:account, name: 'Dee Donor')
    dandelion_donor = FactoryBot.create(:account, name: 'Dan Delion')
    order = @event.orders.create!(account: donor, currency: 'EUR', value: 42.5, payment_completed: true)
    @event.donations.create!(account: donor, order: order, amount: 12.5, payment_completed: true)
    dandelion_order = @event.orders.create!(account: dandelion_donor, currency: 'EUR', value: 5, payment_completed: true, application_fee_paid_to_dandelion: true)
    @event.donations.create!(account: dandelion_donor, order: dandelion_order, amount: 5, payment_completed: true)
    other_event = FactoryBot.create(:event, organisation: @organisation, currency: 'EUR')
    other_donor = FactoryBot.create(:account, name: 'Otto Other')
    other_event.donations.create!(account: other_donor, order: other_event.orders.create!(account: other_donor, currency: 'EUR', value: 7, payment_completed: true),
                                  amount: 7, payment_completed: true)

    sign_in(@account)
    visit "/e/#{@event.slug}/donations"
    # Donations to Dandelion don't reach the event's organisers
    assert page.has_content?('Received €12,50 in donations from this event.')
    assert page.has_content?('Displaying all 2 donations')
    assert_equal '€12,50', find('tr', text: 'Dee Donor').all('td')[1].text.squish
    assert_equal '€5 to Dandelion', find('tr', text: 'Dan Delion').all('td')[1].text.squish
    assert page.has_no_content?('Otto Other')
  end

  # Notes

  test 'an event admin keeps private notes on the event page, which others visiting it do not see' do
    create_event(prices: [0])
    sign_in(@account)
    visit "/e/#{@event.slug}"
    click_link 'Private note'
    fill_in 'Private notes', with: 'Ask the venue about chairs'
    find('button[aria-label="Save notes"]').click
    page.document.synchronize { raise Capybara::ExpectationNotMet, 'notes not saved' unless @event.reload.notes == 'Ask the venue about chairs' }

    visit "/e/#{@event.slug}"
    assert page.has_field?('Private notes', with: 'Ask the venue about chairs')

    sign_in(FactoryBot.create(:account))
    visit "/e/#{@event.slug}"
    assert page.has_content?(@event.name)
    assert page.has_no_field?('Private notes')
    assert page.has_no_content?('Ask the venue about chairs')
  end

  test 'notes can not be read or changed by other events admins, attendees or people signed out' do
    create_event(prices: [0])
    @event.set(notes: 'Secret note')
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)

    [admin_of_another_event, attendee, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get "/e/#{@event.slug}/notes"
      assert last_response.redirect?, account&.email
      refute_includes last_response.body, 'Secret note'
      post "/e/#{@event.slug}/notes", notes: 'Overwritten'
      assert last_response.redirect?, account&.email
    end
    assert_equal 'Secret note', @event.reload.notes
  end

  # Hiding from the homepage

  test 'a site admin hides an event from the homepage and shows it again' do
    create_event(prices: [0], as: :shown, name: 'Shown Gathering')
    create_event(prices: [0], name: 'Hideable Gathering')
    [@shown, @event].each { |event| event.set(has_image: true) }
    site_admin = FactoryBot.create(:account, admin: true)

    visit '/'
    assert page.has_content?('Shown Gathering')
    assert page.has_content?('Hideable Gathering')

    sign_in(site_admin)
    visit '/events'
    find('.block', text: 'Hideable Gathering').hover # its controls show while it's hovered
    find("a[href='/e/#{@event.slug}/do_hide_from_homepage']").click
    assert page.has_css?("a[href='/e/#{@event.slug}/unhide_from_homepage']")
    assert @event.reload.hidden_from_homepage?

    Capybara.reset_sessions!
    visit '/'
    assert page.has_content?('Shown Gathering')
    assert page.has_no_content?('Hideable Gathering')

    sign_in(site_admin)
    visit '/events'
    find('.block', text: 'Hideable Gathering').hover
    find("a[href='/e/#{@event.slug}/unhide_from_homepage']").click
    assert page.has_css?("a[href='/e/#{@event.slug}/do_hide_from_homepage']")
    refute @event.reload.hidden_from_homepage?
  end

  # Email previews

  test 'an event admin previews the confirmation, reminder and feedback request emails without any being sent' do
    create_event(prices: [0], feedback_questions: 'How was it?')
    @event.tickets.create!(account: FactoryBot.create(:account), ticket_type: @event.ticket_types.first, payment_completed: true)
    sign_in_with_rack(@account)

    jobs = Delayed::Job.count
    emails = recorded_emails do
      %w[ticket_email reminder_email feedback_request_email].each do |email|
        get "/e/#{@event.slug}/#{email}"
        assert last_response.ok?, email
        assert_includes last_response.body, %(src="/e/#{@event.slug}/#{email}_preview"), email

        get "/e/#{@event.slug}/#{email}_preview"
        assert last_response.ok?, email
        assert_includes last_response.body, @event.name, email
        assert_includes last_response.headers['Content-Security-Policy'], "script-src 'none'", email
      end
    end
    assert_empty emails
    assert_equal jobs, Delayed::Job.count
  end

  test 'email previews are refused to other events admins, attendees and people signed out' do
    create_event(prices: [0], feedback_questions: 'How was it?')
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)

    [admin_of_another_event, attendee, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      %w[ticket_email reminder_email feedback_request_email].flat_map { |email| [email, "#{email}_preview"] }.each do |path|
        get "/e/#{@event.slug}/#{path}"
        assert last_response.redirect?, "#{path} #{account&.email}"
        assert_equal "/e/#{@event.slug}", URI(last_response.location).path
      end
    end
  end

  # Resending feedback emails

  test 'resending all feedback emails emails the attendees again, but not the unsubscribed or those who have not paid' do
    create_event(prices: [10], feedback_questions: 'How was it?')
    @event.set(start_time: 2.days.ago, end_time: 1.day.ago, sent_feedback_requests_at: 1.hour.ago)
    attendees = Array.new(2) { FactoryBot.create(:account) }
    unsubscribed = FactoryBot.create(:account, unsubscribed_feedback: true)
    unpaid = FactoryBot.create(:account)
    (attendees + [unsubscribed]).each { |account| @event.tickets.create!(account: account, ticket_type: @event.ticket_types.first, price: 10, payment_completed: true) }
    @event.tickets.create!(account: unpaid, ticket_type: @event.ticket_types.first, price: 10, payment_completed: false)
    sign_in_with_rack(@account)

    Delayed::Job.delete_all
    post "/e/#{@event.slug}/resend_all_feedback_emails"
    assert last_response.redirect?

    emails = emails_sent_by_jobs(/send_feedback_requests/)
    assert_equal 1, emails.length
    assert_equal attendees.map(&:email).sort, emails.first.recipients.sort
  end

  test 'resending all feedback emails is refused to other events admins, attendees and people signed out' do
    create_event(prices: [0], feedback_questions: 'How was it?')
    @event.set(start_time: 2.days.ago, end_time: 1.day.ago)
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)

    Delayed::Job.delete_all
    [admin_of_another_event, attendee, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post "/e/#{@event.slug}/resend_all_feedback_emails"
      assert last_response.redirect?, account&.email
      assert_equal "/e/#{@event.slug}", URI(last_response.location).path
    end
    assert_equal 0, Delayed::Job.and(handler: /send_feedback_requests/).count
  end
end
