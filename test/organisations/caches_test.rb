require_relative '../test_config'

# Organisation counts and the caches of each account's organisations, and repairing them
class OrganisationCachesTest < ActiveSupport::TestCase
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
    covers_route 'GET /stats/caches'
    covers_route 'POST /stats/caches/repair'
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
    covers_route 'POST /o/:slug/show_membership/:f'
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
end
