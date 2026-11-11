require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class OrganisationsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def insert_organisationship_without_callbacks(account:, organisation:, **attrs)
    Organisationship.collection.insert_one(
      {
        account_id: account.id,
        organisation_id: organisation.id,
        created_at: Time.now.utc,
        updated_at: Time.now.utc,
        unsubscribed: false
      }.merge(attrs)
    )
  end

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

  test 'creating an organisation' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.build_stubbed(:organisation)
    sign_in(account)
    click_link 'Organisations'
    click_link 'All organisations'
    within('#content') { click_link 'Create an organisation' }
    fill_in 'Organisation name', with: organisation.name
    fill_in 'URL', with: organisation.slug
    click_button 'Save and continue'
    assert page.has_content? 'To accept payments, add details for Stripe or another payment processor.'
  end

  test 'mailgun_domain is reduced to a hostname and must not be the API address' do
    covers 'organisations/mailgun-sending-domain@ba4027'
    create_organisation
    @organisation.assign_attributes(mailgun_api_key: 'key-123', mailgun_region: 'US', mailgun_domain: ' https://MG.example.com/ ')
    assert @organisation.valid?
    assert_equal 'mg.example.com', @organisation.mailgun_domain

    @organisation.mailgun_domain = 'https://api.mailgun.net'
    assert !@organisation.valid?
    assert_includes @organisation.errors[:mailgun_domain], "must be your sending domain from Mailgun's Domains page, not Mailgun's API address"

    @organisation.mailgun_domain = 'not a domain'
    assert !@organisation.valid?
    assert_includes @organisation.errors[:mailgun_domain], 'must be a domain like mg.example.com'
  end

  test 'evm_address must match its EIP-55 checksum when in mixed case' do
    covers 'events/evm-address-checksum@121bf6'
    create_organisation
    # EIP-55's own example address, which checksums to this case
    @organisation.evm_address = ' 0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed '
    assert @organisation.valid?
    assert_equal '0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAed', @organisation.evm_address

    # No checksum to check in one case
    ['0x5aaeb6053f3e94c9b9a09f33669435e7ef1beaed', '0x5AAEB6053F3E94C9B9A09F33669435E7EF1BEAED'].each do |address|
      @organisation.evm_address = address
      assert @organisation.valid?, address
    end

    # One mistyped character, and one letter in the wrong case
    ['0x5aAeb6053F3E94C9b9A09f33669435E7Ef1BeAee', '0x5aaeb6053F3E94C9b9A09f33669435E7Ef1BeAed'].each do |address|
      @organisation.evm_address = address
      assert !@organisation.valid?, address
      assert_includes @organisation.errors[:evm_address], "doesn't match its checksum, so a character may be mistyped: copy it from your wallet again"
    end
  end

  test 'editing an organisation' do
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/edit"
    fill_in 'Organisation name', with: FactoryBot.build_stubbed(:organisation).name
    click_button 'Update organisation'
    assert page.has_content? "Now let's create an event under your new organisation"
  end

  test 'creating an organisation via referral link sets referrer' do
    referrer = FactoryBot.create(:account, username: 'referreruser', has_signed_in: true)
    creator = FactoryBot.create(:account)
    organisation = FactoryBot.build_stubbed(:organisation)

    sign_in(creator)
    visit "/invite/#{referrer.username}"
    fill_in 'Organisation name', with: organisation.name
    fill_in 'URL', with: organisation.slug
    click_button 'Save and continue'

    saved_organisation = Organisation.find_by(slug: organisation.slug)
    assert_equal referrer.id, saved_organisation.referrer_id
  end

  test 'referral link does not self-refer' do
    account = FactoryBot.create(:account, username: 'selfref', has_signed_in: true)
    organisation = FactoryBot.build_stubbed(:organisation)

    sign_in(account)
    visit "/invite/#{account.username}"
    fill_in 'Organisation name', with: organisation.name
    fill_in 'URL', with: organisation.slug
    click_button 'Save and continue'

    saved_organisation = Organisation.find_by(slug: organisation.slug)
    assert_nil saved_organisation.referrer_id
  end

  test 'organisation creator cannot set themselves as referrer via params' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.build_stubbed(:organisation)

    sign_in_with_rack(account)
    post '/o/new', organisation: { name: organisation.name, slug: organisation.slug, referrer_id: account.id }

    saved_organisation = Organisation.find_by(slug: organisation.slug)
    assert saved_organisation
    assert_nil saved_organisation.referrer_id
  end

  test 'organisation unsubscribe token is scoped to organisation' do
    create_organisation
    other_organisation = FactoryBot.create(:organisation)
    account = FactoryBot.create(:account)
    token = account.organisation_unsubscribe_token_for(@organisation)

    assert_nil Account.from_organisation_unsubscribe_token(other_organisation, token)
  end

  test 'organisation unsubscribe rejects arbitrary account_id' do
    create_organisation
    victim = FactoryBot.create(:account)
    victim.organisationships.create!(organisation: @organisation)

    visit "/o/#{@organisation.slug}/unsubscribe?account_id=#{victim.id}"

    assert page.has_current_path?('/accounts/new')
    assert_equal false, victim.organisationships.find_by(organisation: @organisation).unsubscribed
  end

  test 'organisation welcome email website link cannot carry a sign-in token' do
    create_organisation
    @organisation.set(website: 'https://attacker.example/?t=%recipient.token%')
    organisationship = FactoryBot.create(:account).organisationships.create!(organisation: @organisation)

    @organisation.stub(:image, Struct.new(:url).new('https://example.com/logo.png')) do
      organisationship.stub(:organisation, @organisation) do
        html = organisationship.welcome_email_content('<p>Welcome</p>')

        assert_includes html, 'https://attacker.example/?t='
        refute_includes html, '%recipient.token%'
      end
    end
  end

  test 'organisation unsubscribe via token is two-click' do
    create_organisation
    account = FactoryBot.create(:account, email: 'unsub@example.com')
    organisationship = account.organisationships.create!(organisation: @organisation)
    token = account.organisation_unsubscribe_token_for(@organisation)

    visit "/o/#{@organisation.slug}/unsubscribe?token=#{token}"

    assert page.has_content?('Are you sure you want to unsubscribe')
    assert page.has_content?('unsub@example.com')
    click_button 'Yes, unsubscribe'

    assert page.has_content?('was unsubscribed from')
    organisationship.reload
    assert organisationship.unsubscribed
  end

  test 'signed-in organisation unsubscribe redirects to subscriptions' do
    create_organisation
    organisationship = @account.organisationships.find_by(organisation: @organisation)
    sign_in(@account)

    visit "/o/#{@organisation.slug}/unsubscribe"
    click_button 'Yes, unsubscribe'

    assert page.has_current_path?('/accounts/subscriptions')
    organisationship.reload
    assert organisationship.unsubscribed
  end

  test "set_counts counts every organisation's followers, subscribed accounts, monthly donors and donations at once" do
    create_organisation(currency: 'GBP')
    quiet = FactoryBot.create(:organisation)
    follower = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: follower, skip_welcome: true)
    @organisation.organisationships.create!(account: FactoryBot.create(:account), unsubscribed: true, skip_welcome: true)
    globally_unsubscribed = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: globally_unsubscribed, skip_welcome: true)
    globally_unsubscribed.set(unsubscribed: true)
    # Counted once, as the cache holds the id twice
    follower.set(subscribed_organisation_ids_cache: [@organisation.id, @organisation.id])
    donor = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: donor, monthly_donation_method: 'Other', monthly_donation_amount: 10, monthly_donation_currency: 'GBP', skip_welcome: true)
    # A second row of the same donor's, counted once among donors but adding to the total
    insert_organisationship_without_callbacks(account: donor, organisation: @organisation, monthly_donation_method: 'Other', monthly_donation_amount: 5, monthly_donation_currency: 'GBP')
    # A donor whose account has gone isn't counted among donors, though their donation is in the total
    insert_organisationship_without_callbacks(account: FactoryBot.build(:account, id: BSON::ObjectId.new), organisation: @organisation, monthly_donation_method: 'Other', monthly_donation_amount: 3, monthly_donation_currency: 'GBP')
    # A donor with no amount (which saving clears, but older rows have) counts as a donor, adding nothing to the total
    insert_organisationship_without_callbacks(account: FactoryBot.create(:account), organisation: @organisation, monthly_donation_method: 'Other')
    quiet.set(followers_count: 99, subscribed_accounts_count: 99, monthly_donors_count: 99, monthly_donations_count: '£99')

    assert_equal Organisation.count, Organisation.set_counts

    @organisation.reload
    # Every row, the creator's included
    assert_equal 8, @organisation.followers_count
    # The creator, the follower and the donor: not the unsubscribed, nor rows inserted directly, which skip the caches
    assert_equal 3, @organisation.subscribed_accounts_count
    assert_equal 2, @organisation.monthly_donors_count
    assert_equal '£18', @organisation.monthly_donations_count
    quiet.reload
    # Just its creator, and no donors
    assert_equal [1, 1, 0, '0'], [quiet.followers_count, quiet.subscribed_accounts_count, quiet.monthly_donors_count, quiet.monthly_donations_count]
    assert_equal 0, Organisation.set_counts, 'nothing changed, so nothing is written'
  end

  test 'organisation cache sync reports duplicate organisationship rows' do
    create_organisation
    member = FactoryBot.create(:account)
    member.organisationships.create!(organisation: @organisation)
    insert_organisationship_without_callbacks(account: member, organisation: @organisation)

    out_of_sync = Account.check_organisation_cache_sync
    entry = out_of_sync.find { |e| e[:account].id == member.id }
    assert entry
    assert_includes entry[:mismatches], 'duplicate_organisationships'
    assert_equal [{ organisation_id: @organisation.id.to_s, count: 2 }], entry[:duplicates]
    assert_equal 2, Organisationship.and(account: member, organisation: @organisation).count
  end

  test 'an admin sees caches out of sync on /stats/caches and repairs them' do
    create_organisation
    member = FactoryBot.create(:account, name: 'Drifted Member')
    member.organisationships.create!(organisation: @organisation, skip_welcome: true)
    sign_in(FactoryBot.create(:account, admin: true))

    visit '/stats/caches'
    assert page.has_content? 'All in sync'
    assert page.has_no_button? 'Repair'

    member.set(subscribed_organisation_ids_cache: [])
    visit '/stats/caches'
    assert page.has_content? '1 record out of sync'
    within('table') do
      assert page.has_content? 'Drifted Member'
      assert page.has_content? 'subscribed_organisation_ids_cache'
    end

    click_button_and_confirm 'Repair'
    assert page.has_content? 'All in sync'
    assert_equal [@organisation.id], member.reload.subscribed_organisation_ids_cache
  end

  test 'only admins can see /stats/caches or repair caches' do
    create_organisation
    member = FactoryBot.create(:account)
    member.organisationships.create!(organisation: @organisation, skip_welcome: true)
    member.set(subscribed_organisation_ids_cache: [])
    sign_in_with_rack(member)

    get '/stats/caches'
    assert last_response.redirect?
    post '/stats/caches/repair'
    assert last_response.redirect?
    assert_empty member.reload.subscribed_organisation_ids_cache
  end

  test 'organisation cache sync reports nothing when every cache matches its organisationships' do
    create_organisation
    member = FactoryBot.create(:account)
    member.organisationships.create!(organisation: @organisation, skip_welcome: true)
    member.organisationships.create!(organisation: FactoryBot.create(:organisation), unsubscribed: true, hide_membership: true, skip_welcome: true)

    assert_empty Account.check_organisation_cache_sync
  end

  test 'organisation cache sync finds and repairs an organisation an account is cached in without a row for it' do
    create_organisation
    left = FactoryBot.create(:organisation)
    member = FactoryBot.create(:account)
    member.organisationships.create!(organisation: @organisation, skip_welcome: true)
    member.add_to_set(organisation_ids_cache: left.id)
    leaver = FactoryBot.create(:account)
    leaver.set(organisation_ids_cache: [left.id], subscribed_organisation_ids_cache: [left.id])

    out_of_sync = Account.check_organisation_cache_sync
    assert_equal [leaver.id, member.id].sort, out_of_sync.map { |entry| entry[:account].id }.sort
    entry = out_of_sync.find { |e| e[:account].id == member.id }
    assert_equal ['organisation_ids_cache'], entry[:mismatches]
    assert_equal({ current: [@organisation.id, left.id].map(&:to_s).sort, expected: [@organisation.id.to_s] }, entry[:details][:organisation_ids_cache])
    assert_equal %w[organisation_ids_cache subscribed_organisation_ids_cache], out_of_sync.find { |e| e[:account].id == leaver.id }[:mismatches]

    Account.check_organisation_cache_sync(fix: true)
    assert_equal [@organisation.id], member.reload.organisation_ids_cache
    assert_empty leaver.reload.organisation_ids_cache
    assert_empty leaver.subscribed_organisation_ids_cache
    assert_empty Account.check_organisation_cache_sync
  end

  test "unfollowing an organisation takes it off all of the account's organisation caches" do
    create_organisation
    member = FactoryBot.create(:account)
    member.organisationships.create!(organisation: @organisation, skip_welcome: true)

    # As unfollowing does (post '/o/:slug/organisationship')
    member.organisationships.find_by(organisation: @organisation).destroy
    member.reload

    assert_empty member.organisation_ids_cache
    assert_empty member.organisation_ids_public_cache
    assert_empty member.subscribed_organisation_ids_cache
    assert_empty member.unsubscribed_organisation_ids_cache
  end

  test 'hiding and showing a membership on the organisation page takes it off and puts it back on the public cache' do
    create_organisation
    member = FactoryBot.create(:account)
    member.organisationships.create!(organisation: @organisation, skip_welcome: true)
    sign_in(member)

    visit "/o/#{@organisation.slug}"
    click_on 'Showing on your profile'
    assert page.has_link? 'Not showing on your profile'
    assert_empty Account.find(member.id).organisation_ids_public_cache

    click_on 'Not showing on your profile'
    assert page.has_link? 'Showing on your profile'
    assert_equal [@organisation.id], Account.find(member.id).organisation_ids_public_cache
  end

  test 'destroying a duplicate organisationship keeps the organisation in the cache' do
    create_organisation
    member = FactoryBot.create(:account)
    existing = member.organisationships.create!(organisation: @organisation)
    insert_organisationship_without_callbacks(account: member, organisation: @organisation)
    duplicate = Organisationship.and(account: member, organisation: @organisation, :id.ne => existing.id).first

    duplicate.destroy
    member.reload
    assert_includes member.organisation_ids_cache.map(&:to_s), @organisation.id.to_s
    assert_equal 1, member.organisationships.and(organisation: @organisation).count
  end

  test 'organisation cache sync fix dedupes and backfills missing organisation ids' do
    create_organisation
    other = FactoryBot.create(:organisation)
    member = FactoryBot.create(:account)
    member.organisationships.create!(organisation: @organisation)
    insert_organisationship_without_callbacks(account: member, organisation: @organisation)
    insert_organisationship_without_callbacks(account: member, organisation: other)

    Account.check_organisation_cache_sync(fix: true)
    member.reload

    assert_equal 1, Organisationship.and(account: member, organisation: @organisation).count
    assert_equal 1, Organisationship.and(account: member, organisation: other).count
    cached = member.organisation_ids_cache.map(&:to_s)
    assert_includes cached, @organisation.id.to_s
    assert_includes cached, other.id.to_s
    assert_includes member.subscribed_organisation_ids_cache.map(&:to_s), other.id.to_s
  end

  test 'organisation cache sync fix keeps privileges when deduping' do
    create_organisation
    member = FactoryBot.create(:account)
    existing = member.organisationships.create!(organisation: @organisation)
    insert_organisationship_without_callbacks(account: member, organisation: @organisation, admin: true, event_manager: true)

    Account.check_organisation_cache_sync(fix: true)
    existing.reload

    assert_equal 1, Organisationship.and(account: member, organisation: @organisation).count
    assert existing.admin
    assert existing.event_manager
  end

  test 'organisation cache sync fix preserves creditings and stripe connect when deduping' do
    create_organisation(currency: 'GBP')
    member = FactoryBot.create(:account)
    stripe_connect_json = { 'stripe_user_id' => 'acct_duplicate' }.to_json
    existing = member.organisationships.create!(organisation: @organisation)
    insert_organisationship_without_callbacks(
      account: member,
      organisation: @organisation,
      stripe_connect_json: stripe_connect_json,
      stripe_account_json: { 'display_name' => 'Duplicate Connect' }.to_json,
      monthly_donation_method: 'Other',
      monthly_donation_amount: 10.0,
      monthly_donation_currency: 'GBP'
    )
    duplicate = Organisationship.and(account: member, organisation: @organisation, :id.ne => existing.id).first
    crediting = duplicate.creditings.create!(account: member, amount: 25, currency: 'GBP')

    Account.check_organisation_cache_sync(fix: true)
    existing.reload

    assert_equal 1, Organisationship.and(account: member, organisation: @organisation).count
    assert_equal [crediting.id], existing.creditings.pluck(:id)
    assert_equal 25, existing.creditings.first.amount
    assert_equal stripe_connect_json, existing.stripe_connect_json
    assert_includes existing.stripe_account_json, 'Duplicate Connect'
    assert_equal 'Other', existing.monthly_donation_method
    assert_equal 10.0, existing.monthly_donation_amount
    assert_equal Money.new(2500, 'GBP'), existing.credit_granted
  end

  test 'organisation cache sync fix repairs subscribe state drift' do
    create_organisation
    member = FactoryBot.create(:account)
    member.organisationships.create!(organisation: @organisation)
    member.set(
      subscribed_organisation_ids_cache: [],
      unsubscribed_organisation_ids_cache: [@organisation.id]
    )

    out_of_sync = Account.check_organisation_cache_sync
    assert(out_of_sync.any? { |entry| entry[:account].id == member.id && entry[:mismatches].include?('subscribed_organisation_ids_cache') })

    Account.check_organisation_cache_sync(fix: true)
    member.reload
    assert_includes member.subscribed_organisation_ids_cache.map(&:to_s), @organisation.id.to_s
    assert_empty member.unsubscribed_organisation_ids_cache || []
  end

  test 'mass_assigning drops Dragonfly setters that could delete or adopt a stored file' do
    uid = Dragonfly.app.store('victim')
    upload = Rack::Test::UploadedFile.new('app/assets/images/test-event.jpg', 'image/jpeg')
    params = {
      'name' => 'Org', 'image' => upload, 'remove_image' => '1',
      'retained_image' => Dragonfly::Serializer.json_b64_encode('uid' => uid),
      'image_uid' => uid, 'image_url' => 'https://example.com/x.png', 'image_name' => 'x.png'
    }

    assigned = Dandelion::App.new!.mass_assigning(params, Organisation)

    assert_equal %w[image name remove_image], assigned.keys.sort
    assert_equal 'victim', Dragonfly.app.fetch(uid).data
  end

  test 'organisation tier edit rejects organisation_id from params' do
    create_organisation
    organisation_tier = @organisation.organisation_tiers.create!(name: 'Gold', threshold: 100, discount: 10)
    other_organisation = FactoryBot.create(:organisation)

    sign_in_with_rack(@account)
    post "/o/#{@organisation.slug}/organisation_tiers/#{organisation_tier.id}/edit", organisation_tier: { name: 'Gold', threshold: 100, discount: 10, organisation_id: other_organisation.id }

    assert_equal @organisation.id, organisation_tier.reload.organisation_id
  end

  test 'contribution reminder skips Dandelion Stripe Connect' do
    create_organisation(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json)
    @organisation.set(paid_up: false)

    refute @organisation.contribution_reminder
    assert @organisation.payment_method?
    assert_nil EventPaymentMethod.contribution_reminder_label(@organisation)
  end

  test 'contribution reminder asks unpaid stripe_client_id orgs' do
    create_organisation(stripe_client_id: 'ca_test')
    @organisation.set(paid_up: false)

    assert @organisation.contribution_reminder
    assert_equal 'Stripe Connect', EventPaymentMethod.contribution_reminder_label(@organisation)
  end

  test 'contribution reminder asks unpaid Mollie orgs' do
    create_organisation(stripe_pk: nil, stripe_sk: nil, mollie_api_key: 'test_molliekey')
    @organisation.set(paid_up: false)

    assert @organisation.contribution_reminder
    assert_equal 'Mollie', EventPaymentMethod.contribution_reminder_label(@organisation)
  end

  test 'events count the promotion fee paid for them, and nothing for events without ticket sales' do
    covers 'events/contribution-running-total@535bd5'
    create_organisation(currency: 'GBP')
    create_event(fixed_contribution_gbp: 10)
    create_event(as: :event2, promotion_fee_gbp: 25)
    create_event(as: :event3)

    assert_equal Money.new(25 * 100, 'GBP'), @event2.contribution_gbp
    assert_equal Money.new(0, 'GBP'), @event3.contribution_gbp
    assert_equal Money.new(35 * 100, 'GBP'), @organisation.contribution_requested
  end

  test 'secret keys are masked in the edit form and kept when left blank' do
    create_organisation(mollie_api_key: 'test_molliekey1234')
    sign_in(@account)
    edit_mollie_api_key = lambda do
      visit "/o/#{@organisation.slug}/edit"
      click_link 'Payments'
      find('#payment-mollie')
    end

    mollie = edit_mollie_api_key.call
    key = mollie.find_field('organisation_mollie_api_key')
    assert_equal '', key.value
    assert_equal '••••1234', key[:placeholder]
    refute_includes page.html, 'test_molliekey1234'
    click_button 'Update organisation'
    assert page.has_content? 'The organisation was saved'
    assert_equal 'test_molliekey1234', @organisation.reload.mollie_api_key

    edit_mollie_api_key.call.fill_in 'organisation_mollie_api_key', with: 'test_newkey'
    click_button 'Update organisation'
    assert page.has_content? 'The organisation was saved'
    assert_equal 'test_newkey', @organisation.reload.mollie_api_key

    edit_mollie_api_key.call.find('label', text: 'Remove').click
    click_button 'Update organisation'
    assert page.has_content? 'The organisation was saved'
    assert_nil @organisation.reload.mollie_api_key
  end

  test 'organisation admins cannot set contribution or platform-only fields' do
    create_organisation
    sign_in_with_rack(@account)

    %w[percent_requested hide_from_homepage allow_iframes psychedelic allow_purchase_url no_referrer].each do |f|
      error = assert_raises(RuntimeError) { post "/o/#{@organisation.slug}/edit", organisation: { f => f == 'percent_requested' ? '-1000' : '1' } }
      assert_match(/are protected/, error.message)
    end
    @organisation.reload
    assert_nil @organisation.percent_requested
    refute @organisation.hide_from_homepage
  end

  test 'contribution amounts cannot be negative' do
    create_organisation
    @organisation.percent_requested = -1
    @organisation.fixed_contribution_gbp = -1
    refute @organisation.valid?
    assert @organisation.errors[:percent_requested].any?
    assert @organisation.errors[:fixed_contribution_gbp].any?
  end

  test 'stripe setup session is bound to the organisation' do
    create_organisation
    sign_in_with_rack(@account)

    captured = nil
    Stripe::Checkout::Session.stub :create, proc { |params, _opts|
      captured = params
      api_object(id: 'cs_setup')
    } do
      header 'Accept', 'application/json'
      post "/o/#{@organisation.slug}/stripe_setup"
    end

    assert_equal 200, last_response.status
    assert_equal @organisation.id.to_s, captured[:client_reference_id]
  end

  test 'stripe setup complete rejects a session created for another organisation' do
    create_organisation
    other = FactoryBot.create(:organisation, account: @account)
    sign_in_with_rack(@account)

    session = api_object(mode: 'setup', client_reference_id: other.id.to_s, customer: 'cus_other')
    Stripe::Checkout::Session.stub :retrieve, session do
      get "/o/#{@organisation.slug}/stripe_setup_complete", session_id: 'cs_other'
    end

    assert_equal 400, last_response.status
    assert_nil @organisation.reload.stripe_customer_id
  end

  test 'events block rejects requests that are not XHR' do
    create_event
    get "/o/#{@organisation.slug}/events_block?events_page=2"
    assert_equal 400, last_response.status

    get "/o/#{@organisation.slug}/events_block", {}, { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
    assert last_response.ok?
    assert_includes last_response.body, @event.name
  end

  test 'embedded events list shows at most 100 events, then links to all events' do
    create_organisation
    FactoryBot.create_list(:event, 100, organisation: @organisation)
    get "/o/#{@organisation.slug}/events?minimal=true&from=2026-01-01", {}, { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
    assert last_response.ok?
    assert_not_includes last_response.body, 'See all events'

    FactoryBot.create(:event, organisation: @organisation)
    get "/o/#{@organisation.slug}/events?minimal=true&from=2026-01-01", {}, { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
    assert last_response.ok?
    assert_equal 100, last_response.body.scan('class="mb-4"').length
    assert_includes last_response.body, "href=\"/o/#{@organisation.slug}/events?from=2026-01-01\" target=\"_blank\">See all events"
  end

  test 'event cards are cached, and served from the cache on the next render' do
    create_event(as: :event1)
    create_event(as: :event2)
    get "/o/#{@organisation.slug}/events", {}, { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
    assert last_response.ok?
    assert_includes last_response.body, @event1.name
    assert_equal 2, Fragment.count

    Fragment.all.each { |fragment| fragment.set(value: '<p>cached card</p>') }
    get "/o/#{@organisation.slug}/events", {}, { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }
    assert_equal 2, last_response.body.scan('cached card').length
    assert_not_includes last_response.body, @event1.name
  end

  test 'the events grid and featured carousel serve their event cards from the cache' do
    create_event(as: :event1, featured: true, has_image: true)
    create_event(as: :event2, featured: true, has_image: true)
    [@event1, @event2].each { |event| event.set(has_image: true) }
    get "/o/#{@organisation.slug}/events?display=grid"
    assert last_response.ok?
    assert_equal 2, last_response.body.scan('event-block"').length
    assert_equal 2, Fragment.count
    # The carousel's cards share the grid's cache keys
    get "/o/#{@organisation.slug}/carousels/featured"
    assert last_response.ok?
    assert_equal 2, last_response.body.scan('slick-item"').length
    assert_equal 2, Fragment.count

    Fragment.all.each { |fragment| fragment.set(value: '<p>cached card</p>') }
    get "/o/#{@organisation.slug}/events?display=grid"
    assert_equal 2, last_response.body.scan('cached card').length
    get "/o/#{@organisation.slug}/carousels/featured"
    assert_equal 2, last_response.body.scan('cached card').length
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

  # Creates an organisation in the browser, landing on its Payments tab
  def create_organisation_in_browser(name, slug)
    visit '/o/new'
    fill_in 'Organisation name', with: name
    fill_in 'URL', with: slug
    click_button 'Save and continue'
    assert page.has_content? 'To accept payments, add details for Stripe or another payment processor.'
  end

  test 'a new organisation takes the currency of where you are, or your own default currency, and it can be changed in the Payments tab' do
    covers 'organisations/currency-defaults-to-local@019877'
    account = FactoryBot.create(:account)
    sign_in(account)
    # Cloudflare's guess at the visitor's country
    page.driver.headers = { 'CF-IPCountry' => 'SE' }

    create_organisation_in_browser('Stockholm Circle', 'stockholm-circle')
    assert_equal 'SEK', Organisation.find_by(slug: 'stockholm-circle').currency

    account.set(default_currency: 'CAD')
    create_organisation_in_browser('Toronto Circle', 'toronto-circle')
    assert_equal 'CAD', Organisation.find_by(slug: 'toronto-circle').currency

    find('#organisation_currency').find("option[value='NOK']").select_option
    click_button 'Update organisation'
    assert page.has_content? 'The organisation was saved'
    assert_equal 'NOK', Organisation.find_by(slug: 'toronto-circle').currency
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

  def enable_affiliate_credits
    create_organisation(currency: 'GBP', affiliate_credit_percentage: 10)
    create_event(prices: [10], suggested_donation: 0)
  end

  # Books quantity tickets for buyer through Stripe, via the link the attendee's order confirmation gives them, and
  # completes the payment
  def book_via_affiliate_link(buyer, affiliate, quantity: 1)
    header 'Accept', 'application/json'
    Stripe::Checkout::Session.stub(:create, api_object(id: "cs_#{SecureRandom.hex(4)}", payment_intent: "pi_#{SecureRandom.hex(4)}", url: 'https://checkout.stripe.com/test')) do
      post "/e/#{@event.slug}/purchase",
           ticketForm: { quantities: { @event.ticket_types.first.id.to_s => quantity.to_s }, affiliate_type: 'Account', affiliate_id: affiliate.id.to_s },
           detailsForm: { payment_method: 'stripe', account: { name: buyer.name, email: buyer.email } }
    end
    assert_equal 200, last_response.status, last_response.body
    order = @event.orders.order('created_at desc').first
    order.set(payment_completed: true)
    order
  end

  test "an attendee's order confirmation email has their personal affiliate link" do
    covers 'organisations/affiliate-link-in-confirmation@7d220b'
    enable_affiliate_credits
    attendee = FactoryBot.create(:account)
    order = @event.orders.create!(account: attendee, currency: 'GBP', value: 10, payment_completed: true)
    @event.tickets.create!(account: attendee, order: order, ticket_type: @event.ticket_types.first, payment_completed: true)

    email = lambda do
      tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: attendee)
      EmailHelper.html(:tickets, event: @event.reload, order: order, account: attendee, tickets_table: tickets_table, header_image_url: nil)
    end
    affiliate_link = "#{ENV['BASE_URI']}/e/#{@event.slug}?affiliate_type=Account&amp;affiliate_id=#{attendee.id}"
    assert_match(/<a href="#{Regexp.escape(affiliate_link)}"[^>]*>Here's your affiliate link for this event.<\/a>/, email.call)
    assert_includes email.call, 'equal to 10% of the order value'

    # The link fills in the booking form's affiliate
    get "/e/#{@event.slug}?affiliate_type=Account&affiliate_id=#{attendee.id}"
    assert_match(/name="affiliate_id"[^>]*value="#{attendee.id}"|value="#{attendee.id}"[^>]*name="affiliate_id"/, last_response.body)

    @organisation.set(affiliate_credit_percentage: nil)
    refute_includes email.call, 'affiliate link'
  end

  test 'a referrer earns the set percentage of each order made via their link as credit, but not on their own orders' do
    covers 'organisations/affiliate-credit-percentage@90cfee'
    enable_affiliate_credits
    referrer = FactoryBot.create(:account)
    referrership = @organisation.organisationships.create!(account: referrer)

    order = book_via_affiliate_link(FactoryBot.create(:account), referrer, quantity: 3)
    assert_equal referrer.id, order.affiliate_id
    assert_equal 30, order.value
    assert_equal Money.new(300, 'GBP'), referrership.credit_granted

    book_via_affiliate_link(FactoryBot.create(:account), referrer)
    assert_equal Money.new(400, 'GBP'), referrership.credit_granted

    # Their own order, via their own link, earns nothing
    own_order = book_via_affiliate_link(referrer, referrer, quantity: 5)
    assert_nil own_order.affiliate_id
    assert_equal Money.new(400, 'GBP'), referrership.reload.credit_granted
    # Nor does one marked as theirs some other way
    own_order.set(affiliate_type: 'Account', affiliate_id: referrer.id)
    assert_equal Money.new(400, 'GBP'), referrership.reload.credit_granted
  end

  test 'credit earned through referrals is applied when the referrer books a future event' do
    covers 'organisations/credit-applied-at-checkout@ebe0b1'
    enable_affiliate_credits
    referrer = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: referrer)
    # Ten £10 tickets booked through their link: £10 of credit
    @event.orders.create!(account: FactoryBot.create(:account), currency: 'GBP', value: 100, affiliate_type: 'Account', affiliate_id: referrer.id,
                          payment_completed: true)
    create_event(as: :future_event, prices: [10], suggested_donation: 0)

    sign_in(referrer)
    visit "/e/#{@future_event.slug}"
    select 1, from: "quantities[#{@future_event.ticket_types.first.id}]"
    click_button 'Use credit'
    assert page.has_content? 'Thanks for booking'
    order = @future_event.orders.find_by(account: referrer)
    assert_equal 10, order.credit_applied
    assert order.payment_completed
    assert_equal Money.new(0, 'GBP'), @organisation.organisationships.find_by(account: referrer).credit_balance
  end

  test "an attendee's credit balance shows on the organisation page, and its breakdown of credit earned and used" do
    covers 'organisations/credit-balance-shown@e73de3'
    enable_affiliate_credits
    referrer = FactoryBot.create(:account)
    referred = FactoryBot.create(:account, name: 'Referred Person')
    book_via_affiliate_link(referred, referrer, quantity: 3)
    referrership = @organisation.organisationships.find_or_create_by!(account: referrer)
    create_event(as: :future_event, prices: [1], suggested_donation: 0)
    @future_event.orders.create!(account: referrer, currency: 'GBP', value: 0, credit_applied: 1, payment_completed: true)

    sign_in_with_rack(referrer)
    get "/o/#{@organisation.slug}"
    assert last_response.ok?
    assert_includes last_response.body, %(href="/organisationships/#{referrership.id}/credit_balance">£2 credit</a>)

    get "/organisationships/#{referrership.id}/credit_balance"
    assert last_response.ok?
    assert_includes last_response.body, '<span class="badge text-bg-primary">£2</span>'
    assert_includes last_response.body, "£3.00 for Referred Person&#39;s order to #{@event.name}"
    assert_includes last_response.body, "£1.00 on #{@future_event.name}"

    # Not someone else's
    sign_in_with_rack(referred)
    get "/organisationships/#{referrership.id}/credit_balance"
    refute last_response.ok?
    get "/o/#{@organisation.slug}"
    refute_includes last_response.body, 'credit</a>'
  end

  # An organisation taking payment through Dandelion's Stripe Connect, so that checkout donations go to Dandelion
  # while it's behind with its contribution
  def create_stripe_connect_organisation
    create_organisation(currency: 'GBP', stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json)
  end

  # Completed ticket sales of these prices
  def sell_tickets(event, *prices)
    prices.each do |price|
      buyer = FactoryBot.create(:account)
      order = event.orders.create!(account: buyer, currency: event.currency, value: price, payment_completed: true)
      event.tickets.create!(account: buyer, order: order, ticket_type: event.ticket_types.first, price: price, payment_completed: true)
    end
  end

  def contribute(amount)
    @organisation.organisation_contributions.create!(amount: amount, currency: 'GBP', payment_completed: true)
    @organisation.update_paid_up_without_delay
  end

  test 'checkout takes only the donation to Dandelion, never the contribution, out of a ticket sale' do
    covers 'events/contribution-never-from-ticket-sales@73c546'
    create_stripe_connect_organisation
    create_event(prices: [100], suggested_donation: 5)
    @organisation.set(paid_up: false)
    assert @event.reload.donations_to_dandelion?

    checkout = lambda do |ticket_form|
      buyer = FactoryBot.create(:account)
      session_params = nil
      Stripe::Checkout::Session.stub(:create, proc { |params, _opts|
        session_params = params
        api_object(id: "cs_#{buyer.id}", payment_intent: "pi_#{buyer.id}", url: 'https://checkout.stripe.com/test')
      }) do
        header 'Accept', 'application/json'
        post "/e/#{@event.slug}/purchase",
             ticketForm: { quantities: { @event.ticket_types.first.id.to_s => '1' } }.merge(ticket_form),
             detailsForm: { payment_method: 'stripe', account: { name: buyer.name, email: buyer.email } }
      end
      assert_equal 200, last_response.status, last_response.body
      session_params
    end

    assert_equal 0, checkout.call({})[:payment_intent_data][:application_fee_amount]
    assert_equal 500, checkout.call({ donation_amount: '5' })[:payment_intent_data][:application_fee_amount]

    @organisation.set(paid_up: true)
    refute @event.reload.donations_to_dandelion?
    assert_nil checkout.call({ donation_amount: '5' })[:payment_intent_data][:application_fee_amount]
  end

  test 'each ticket sale adds 1% of its price to the contribution, and the Contribute page shows the total, what was contributed and what is left' do
    covers 'events/contribution-never-from-ticket-sales@73c546', 'events/contribution-running-total@535bd5'
    create_stripe_connect_organisation
    create_event(as: :event1, prices: [100])
    create_event(as: :event2, prices: [50])
    create_event(as: :no_sales_event)
    sell_tickets(@event1, 100, 100, 100)
    sell_tickets(@event2, 50, 50)

    assert_equal Money.new(300, 'GBP'), @event1.contribution_gbp
    assert_equal Money.new(100, 'GBP'), @event2.contribution_gbp
    assert_equal Money.new(0, 'GBP'), @no_sales_event.contribution_gbp
    assert_equal Money.new(400, 'GBP'), @organisation.contribution_requested

    contribute(1.5)
    sign_in_with_rack(@account)
    get "/o/#{@organisation.slug}/contribute"
    assert last_response.ok?
    assert_match(/contributed\s+£1.50\s+of a\s+suggested £4,\s+leaving a balance of £2.50\./, last_response.body)
  end

  test 'checkout donations go to the organisation while it has contributed 90% with no more than £100 outstanding, and back to Dandelion when it falls behind' do
    covers 'events/contribution-never-from-ticket-sales@73c546', 'events/contribution-keeping-up@ab2a3a', 'events/checkout-donations-to-dandelion@f1a028'
    create_stripe_connect_organisation
    create_event(prices: [10_000], suggested_donation: 5, minimum_donation: 3)
    sell_tickets(@event, *[10_000] * 10) # £1000 to contribute

    contribute(899)
    refute @organisation.reload.paid_up
    assert @event.reload.donations_to_dandelion?

    contribute(1) # 90%, £100 outstanding
    assert @organisation.reload.paid_up
    refute @event.reload.donations_to_dandelion?
    # The event's Donations settings take effect
    donation = @event.donations.new(account: @account, amount: 2)
    refute donation.valid?
    assert_includes donation.errors[:amount], 'is insufficient'

    # More sales: 90% of £1100 contributed, but £110 outstanding
    sell_tickets(@event, 10_000)
    @organisation.update_paid_up_without_delay
    refute @organisation.reload.paid_up
    assert @event.reload.donations_to_dandelion?
    donation = @event.donations.new(account: @account, amount: 2)
    donation.valid?
    assert_empty donation.errors[:amount]
  end

  test 'auto top-up tops the organisation up to 100% when it falls behind, so checkout donations always go to it' do
    covers 'events/contribution-auto-top-up@6c1573'
    create_stripe_connect_organisation
    create_event(prices: [10_000])
    sell_tickets(@event, *[10_000] * 5) # £500 to contribute
    contribute(450)
    @organisation.set(stripe_customer_id: 'cus_test')

    # Keeping up, so nothing to top up
    Stripe::PaymentIntent.stub(:create, proc { raise 'charged while keeping up' }) { @organisation.stripe_topup }

    @organisation.update_paid_up_without_delay
    assert @organisation.reload.paid_up
    sell_tickets(@event, *[10_000] * 5) # £1000, 45% contributed
    @organisation.update_paid_up_without_delay
    # Behind, but still sending checkout donations to the organisation
    assert @organisation.reload.paid_up
    refute @event.reload.donations_to_dandelion?

    charged = nil
    Stripe::Customer.stub(:list_payment_methods, [api_object(id: 'pm_test')]) do
      Stripe::PaymentIntent.stub(:create, proc { |params, _opts|
        charged = params
        api_object(id: 'pi_topup')
      }) { @organisation.stripe_topup }
    end
    assert_equal [55_000, 'GBP', 'cus_test', 'pm_test'], charged.values_at(:amount, :currency, :customer, :payment_method)
    assert_equal 550, @organisation.organisation_contributions.find_by(payment_intent: 'pi_topup').amount
    assert_equal Money.new(0, 'GBP'), @organisation.contribution_remaining
  end

  # The state in the organisation's Connect Stripe link on its Payments tab, as the signed-in account sees it
  def stripe_connect_state_from_payments_tab
    get "/o/#{@organisation.slug}/edit"
    link = Nokogiri::HTML(last_response.body).at_css('a[href^="https://connect.stripe.com/oauth/authorize"]')
    assert link, 'no Connect Stripe link on the Payments tab'
    Rack::Utils.parse_query(URI(link['href']).query).fetch('state')
  end

  # Stripe's OAuth token exchange and account lookup, answering for acct_own and recording the codes exchanged, so no
  # request reaches Stripe
  def stub_stripe_connect(&)
    exchanged = []
    connection = Object.new
    connection.define_singleton_method(:post) do |url, body|
      exchanged << [url, body[:code]]
      Struct.new(:success?, :body).new(true, { stripe_user_id: 'acct_own' }.to_json)
    end
    Faraday.stub(:new, ->(*) { connection }) do
      Stripe::Account.stub(:retrieve, ->(id, _opts) { { id: id, business_profile: { name: 'Own Ltd' } } }, &)
    end
    exchanged
  end

  def stripe_connect_callback(state)
    get '/organisations/stripe_connect', code: 'ac_code', state: state
  end

  test "an organisation admin's own Connect state connects the Stripe account they authorised" do
    create_organisation(stripe_pk: nil, stripe_sk: nil)
    sign_in_with_rack(@account)
    state = stripe_connect_state_from_payments_tab

    exchanged = stub_stripe_connect { stripe_connect_callback(state) }

    assert_equal [['https://connect.stripe.com/oauth/token', 'ac_code']], exchanged
    assert_equal 'acct_own', @organisation.reload.stripe_user_id
    assert_equal 'Own Ltd', @organisation.stripe_account_name
    assert_equal "/o/#{@organisation.slug}/edit", URI(last_response.location).path
  end

  test "a Connect state started by one account doesn't connect the organisation when another admin opens its callback" do
    create_organisation(stripe_pk: nil, stripe_sk: nil)
    other_admin = FactoryBot.create(:account)
    other_admin.organisationships.create!(organisation: @organisation, admin: true)
    assert Organisation.admin?(@organisation, other_admin)
    sign_in_with_rack(other_admin)
    state = stripe_connect_state_from_payments_tab

    sign_in_with_rack(@account)
    exchanged = stub_stripe_connect { stripe_connect_callback(state) }

    assert_empty exchanged
    assert_nil @organisation.reload.stripe_connect_json
    follow_redirect!
    assert_includes last_response.body, 'Stripe connection failed security check'
  end

  test 'a Connect state minted without an account, before states were bound to one, is refused' do
    create_organisation(stripe_pk: nil, stripe_sk: nil)
    state = TokenVerifier.generate("stripe_connect_org:#{@organisation.id}", expires_in: 15.minutes, purpose: 'stripe_connect')
    sign_in_with_rack(@account)

    exchanged = stub_stripe_connect { stripe_connect_callback(state) }

    assert_empty exchanged
    assert_nil @organisation.reload.stripe_connect_json
  end

  test 'the Payments tab shows the connected Stripe account and offers to disconnect it' do
    create_organisation(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { stripe_user_id: 'acct_connected' }.to_json, stripe_account_json: { business_profile: { name: 'Connected Ltd' } }.to_json)
    sign_in(@account)
    visit "/o/#{@organisation.slug}/edit"
    click_link 'Payments'

    assert page.has_content?("Connected to Connected Ltd's Stripe account (id: acct_connected)")
    assert page.has_link?('Disconnect')
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
