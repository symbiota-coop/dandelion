require_relative '../test_config'

# Followers: monthly donors, from Patreon, GoCardless or by hand, importing and adding them
class OrganisationFollowersTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # A Faraday connection that answers Patreon's token and members requests from stubs: members is a list of
  # [member, pledge events]
  def patreon_connection(members: [], token_status: 200)
    stubs = Faraday::Adapter::Test::Stubs.new
    json = { 'Content-Type' => 'application/json' }
    stubs.post('/api/oauth2/token') do
      [token_status, json, (token_status == 200 ? { access_token: 'access', refresh_token: 'new-refresh' } : { error: 'invalid_grant' }).to_json]
    end
    stubs.get('/api/oauth2/v2/campaigns') { [200, json, { data: [{ id: '1', type: 'campaign', attributes: { currency: 'USD' } }] }.to_json] }
    stubs.get('/api/oauth2/v2/campaigns/1/members') do
      data = members.map.with_index do |(attributes, events), i|
        { id: "m#{i}", type: 'member', attributes: attributes,
          relationships: { pledge_history: { data: events.map.with_index { |_, j| { id: "e#{i}-#{j}", type: 'pledge-event' } } } } }
      end
      included = members.each_with_index.flat_map do |(_, events), i|
        events.map.with_index { |attributes, j| { id: "e#{i}-#{j}", type: 'pledge-event', attributes: attributes } }
      end
      [200, json, { data: data, included: included, meta: { pagination: { cursors: { next: nil } } } }.to_json]
    end
    Faraday.new(url: OrganisationMonthlyDonations::PATREON_API) do |f|
      f.request :url_encoded
      f.response :raise_error
      f.response :json
      f.adapter :test, stubs
    end
  end

  test 'syncing Patreon records active patrons in the currency they pay and clears those who stopped' do
    covers 'organisations/monthly-donors-synced@c49f69', 'organisations/patreon-pledge-currency@991e09'
    create_organisation(currency: 'GBP', patreon_client_id: 'client', patreon_client_secret: 'secret', patreon_refresh_token: 'refresh')
    recorded_by_hand = @organisation.organisationships.create!(account: FactoryBot.create(:account, email: 'jl@example.com'), monthly_donation_method: 'Other',
                                                               monthly_donation_amount: 11.5, monthly_donation_currency: 'GBP', sent_monthly_donation_welcome: true)
    lapsed = @organisation.organisationships.create!(account: FactoryBot.create(:account), monthly_donation_method: 'Patreon',
                                                     monthly_donation_amount: 5, monthly_donation_currency: 'USD', sent_monthly_donation_welcome: true)
    members = [
      [{ email: 'JL@example.com', full_name: 'JL', patron_status: 'active_patron', pledge_relationship_start: '2026-09-14T10:00:00.000+00:00', pledge_cadence: 1, currently_entitled_amount_cents: 800 },
       [{ type: 'pledge_start', amount_cents: 1000, currency_code: 'CAD', date: '2026-09-14T10:00:00.000+00:00' },
        { type: 'subscription', amount_cents: 1000, currency_code: 'CAD', date: '2026-10-01T10:00:00.000+00:00' },
        { type: 'pledge_upgrade', amount_cents: 1150, currency_code: 'CAD', date: '2026-10-10T10:00:00.000+00:00' }]],
      [{ email: 'declined@example.com', full_name: 'Declined', patron_status: 'declined_patron', currently_entitled_amount_cents: 500 }, []]
    ]

    @organisation.stub(:patreon_connection, patreon_connection(members: members)) { @organisation.sync_with_patreon }

    assert_equal ['Patreon', 11.5, 'CAD', Date.new(2026, 9, 14), false],
                 [recorded_by_hand.reload.monthly_donation_method, recorded_by_hand.monthly_donation_amount, recorded_by_hand.monthly_donation_currency,
                  recorded_by_hand.monthly_donation_start_date, recorded_by_hand.monthly_donation_annual]
    assert_nil lapsed.reload.monthly_donation_method
    assert_nil Account.find_by(email: 'declined@example.com')
    assert_equal 'new-refresh', @organisation.reload.patreon_refresh_token
    assert_nil @organisation.patreon_sync_error
  end

  test 'a rejected Patreon refresh token is reported and leaves patrons as they were' do
    create_organisation(currency: 'GBP', patreon_client_id: 'client', patreon_client_secret: 'secret', patreon_refresh_token: 'refresh')
    patron = @organisation.organisationships.create!(account: FactoryBot.create(:account), monthly_donation_method: 'Patreon',
                                                     monthly_donation_amount: 5, monthly_donation_currency: 'USD', sent_monthly_donation_welcome: true)

    @organisation.stub(:patreon_connection, patreon_connection(token_status: 400)) { @organisation.sync_with_patreon }

    assert_equal ['Patreon', 5.0], [patron.reload.monthly_donation_method, patron.monthly_donation_amount]
    assert_includes @organisation.reload.patreon_sync_error, 'refresh token'
    assert_equal 'refresh', @organisation.patreon_refresh_token
  end

  test 'admins can record, update or clear a monthly donor by hand on the followers page, but not one synced from Patreon' do
    covers 'organisations/monthly-donation-by-hand@ec117b'
    create_organisation(currency: 'GBP')
    donor = @organisation.organisationships.create!(account: FactoryBot.create(:account), sent_monthly_donation_welcome: true)
    @organisation.set(monthly_donors_count: 1)
    assert @organisation.monthly_donations_enabled?
    donor_box = "[data-pagelet-url='/organisationships/#{donor.id}/monthly_donation']"

    sign_in(@account)
    visit "/o/#{@organisation.slug}/followers"
    # The amount and currency each save as they change, and the box comes back with what was saved
    find("#{donor_box} input[name='amount']").set('10')
    assert page.has_css? "#{donor_box} input[name='amount'][value^='10']"
    find("#{donor_box} select[name='currency']").find("option[value='USD']").select_option
    assert page.has_css? "#{donor_box} select[name='currency'] option[value='USD'][selected]"
    assert_equal ['Other', 10.0, 'USD'], [donor.reload.monthly_donation_method, donor.monthly_donation_amount, donor.monthly_donation_currency]

    find("#{donor_box} select[name='currency']").find("option[value='GBP']").select_option
    assert page.has_css? "#{donor_box} select[name='currency'] option[value='GBP'][selected]"
    assert_equal 'GBP', donor.reload.monthly_donation_currency
    @organisation.set_counts
    assert_equal '£10', @organisation.reload.monthly_donations_count

    find("#{donor_box} input[name='amount']").set('')
    assert page.has_css? "#{donor_box} input[name='amount']:not([value^='10'])"
    assert_equal [nil, nil], [donor.reload.monthly_donation_method, donor.monthly_donation_amount]
    refute donor.monthly_donor?

    patron = @organisation.organisationships.create!(account: FactoryBot.create(:account), monthly_donation_method: 'Patreon',
                                                     monthly_donation_amount: 8, monthly_donation_currency: 'USD', sent_monthly_donation_welcome: true)
    visit "/o/#{@organisation.slug}/followers"
    within("[data-pagelet-url='/organisationships/#{patron.id}/monthly_donation']") do
      assert page.has_content? 'via Patreon'
      assert page.has_no_field? 'amount'
    end
  end

  test "a monthly donation recorded by hand without a currency the form offers takes the organisation's" do
    create_organisation(currency: 'GBP')
    donor = @organisation.organisationships.create!(account: FactoryBot.create(:account), sent_monthly_donation_welcome: true)
    @organisation.set(monthly_donors_count: 1)
    sign_in_with_rack(@account)

    [{}, { currency: 'XYZ' }].each do |currency|
      post "/organisationships/#{donor.id}/monthly_donation", amount: '10', **currency
      assert_equal 200, last_response.status
      assert_equal ['Other', 10.0, 'GBP'], [donor.reload.monthly_donation_method, donor.monthly_donation_amount, donor.monthly_donation_currency]
    end
  end

  test 'a monthly donation synced from Patreon cannot be changed by hand' do
    covers 'organisations/monthly-donation-by-hand@ec117b'
    create_organisation(currency: 'GBP')
    @organisation.set(monthly_donors_count: 1)
    sign_in_with_rack(@account)

    patron = @organisation.organisationships.create!(account: FactoryBot.create(:account), monthly_donation_method: 'Patreon',
                                                     monthly_donation_amount: 8, monthly_donation_currency: 'USD', sent_monthly_donation_welcome: true)
    get "/organisationships/#{patron.id}/monthly_donation"
    assert_includes last_response.body, 'via Patreon'
    refute_includes last_response.body, "/organisationships/#{patron.id}/monthly_donation"

    post "/organisationships/#{patron.id}/monthly_donation", amount: '10'
    assert_equal 403, last_response.status
    assert_equal ['Patreon', 8.0], [patron.reload.monthly_donation_method, patron.monthly_donation_amount]
  end

  test 'admins can filter members by how they donate monthly' do
    create_organisation
    { 'patron@example.com' => 'Patreon', 'direct-debit@example.com' => 'GoCardless', 'follower@example.com' => nil }.each do |email, method|
      @organisation.organisationships.create!(account: FactoryBot.create(:account, email: email), monthly_donation_method: method,
                                              monthly_donation_amount: (5 if method), monthly_donation_currency: ('GBP' if method), sent_monthly_donation_welcome: true)
    end
    sign_in_with_rack(@account)

    { 'Patreon' => ['patron@example.com'], 'All' => ['patron@example.com', 'direct-debit@example.com'], 'None' => ['follower@example.com'],
      '' => ['patron@example.com', 'direct-debit@example.com', 'follower@example.com'] }.each do |filter, emails|
      get "/o/#{@organisation.slug}/followers", monthly_donor: filter
      assert_equal emails.sort, %w[patron@example.com direct-debit@example.com follower@example.com].select { |e| last_response.body.include?(e) }.sort, filter
    end
  end

  test 'importing followers from a CSV' do
    create_organisation
    utf16 = "\uFEFFName\tEmail\nAlice\t Alice@example.com \n\t\n".encode(Encoding::UTF_16LE).b
    csv = ImportFromCsv.sanitize(utf16)
    assert_nil ImportFromCsv.error(csv)
    @organisation.import_from_csv_without_delay(csv, :organisationships)
    alice = Account.find_by(email: 'alice@example.com')
    assert_equal 'Alice', alice.name
    assert @organisation.organisationships.find_by(account: alice)

    assert_equal 'The CSV needs a column headed email', ImportFromCsv.error("Name,Email Address\nBob,bob@example.com\n")
    assert_equal "The CSV couldn't be read (there's a problem on line 2)", ImportFromCsv.error("Name,Email\nBob,\"bob\"@example.com\n")
  end

  # GoCardless's API client, answering with these active subscriptions, each [subscription, customer]
  def gocardless_client(subscriptions)
    records = subscriptions.map(&:first)
    customers = subscriptions.to_h { |subscription, customer| [subscription.links.mandate, customer] }
    list = api_object(records: records, after: nil)
    subscriptions_service = Object.new
    subscriptions_service.define_singleton_method(:list) { |params:| params[:status] == 'active' ? list : raise }
    mandates = customers.keys.to_h { |id| [id, api_object(links: api_object(customer: id))] }
    mandates_service = Object.new
    mandates_service.define_singleton_method(:get) { |id| mandates.fetch(id) }
    customers_service = Object.new
    customers_service.define_singleton_method(:get) { |id| customers.fetch(id) }
    api_object(subscriptions: subscriptions_service, mandates: mandates_service, customers: customers_service)
  end

  def gocardless_subscription(id, amount:, currency:, name: 'Monthly donation')
    api_object(status: 'active', name: name, amount: amount, currency: currency, start_date: '2026-09-01', links: api_object(mandate: "MD#{id}"))
  end

  test 'syncing GoCardless records active subscribers as monthly donors and clears those who stopped' do
    covers 'organisations/monthly-donors-synced@c49f69'
    create_organisation(currency: 'GBP', gocardless_access_token: 'token', gocardless_subscriptions: true)
    lapsed = @organisation.organisationships.create!(account: FactoryBot.create(:account), monthly_donation_method: 'GoCardless',
                                                     monthly_donation_amount: 5, monthly_donation_currency: 'GBP', sent_monthly_donation_welcome: true)
    existing = FactoryBot.create(:account, email: 'existing@example.com')
    client = gocardless_client([
                                 [gocardless_subscription(1, amount: 1000, currency: 'GBP'),
                                  api_object(given_name: 'Ex', family_name: 'Isting', email: ' Existing@example.com ', postal_code: nil)],
                                 [gocardless_subscription(2, amount: 12_000, currency: 'EUR', name: 'Annual donation'),
                                  api_object(given_name: 'New', family_name: 'Donor', email: 'new.donor@example.com', postal_code: nil)]
                               ])

    GoCardlessPro::Client.stub(:new, client) { @organisation.sync_with_gocardless }

    organisationship = @organisation.organisationships.find_by(account: existing)
    assert_equal ['GoCardless', 10.0, 'GBP'], [organisationship.monthly_donation_method, organisationship.monthly_donation_amount, organisationship.monthly_donation_currency]
    new_donor = @organisation.organisationships.find_by(account: Account.find_by(email: 'new.donor@example.com'))
    # An annual subscription counts as a twelfth of it a month
    assert_equal ['GoCardless', 10.0, 'EUR'], [new_donor.monthly_donation_method, new_donor.monthly_donation_amount, new_donor.monthly_donation_currency]
    assert new_donor.monthly_donation_annual
    assert_nil lapsed.reload.monthly_donation_method
    assert_nil lapsed.monthly_donation_amount
  end

  test 'admins add a follower by email, making an account for an email that has none, and are told if they already follow' do
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/followers"
    click_link 'Add a follower'
    fill_in 'Email', with: 'new.follower@example.com'
    click_button 'Add follower'
    assert page.has_content? 'new.follower'
    follower = Account.find_by(email: 'new.follower@example.com')
    assert_equal 'new.follower', follower.name
    assert @organisation.organisationships.find_by(account: follower)

    click_link 'Add a follower'
    fill_in 'Email', with: ' New.Follower@example.com '
    click_button 'Add follower'
    assert page.has_content? 'That person is already following the organisation'
    assert_equal 1, Account.and(email: 'new.follower@example.com').count
  end
end
