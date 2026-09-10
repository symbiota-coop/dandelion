require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class OrganisationsTest < ActiveSupport::TestCase
  include Capybara::DSL

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
    assert page.has_content? 'To accept payments, now add details for Stripe or another payment processor.'
  end

  test 'editing an organisation' do
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/edit"
    fill_in 'Organisation name', with: FactoryBot.build_stubbed(:organisation).name
    click_button 'Update organisation'
    assert page.has_content? "Now let's create an event under your new organisation."
  end

  test 'creating an organisation via referral link sets referrer' do
    referrer = FactoryBot.create(:account, username: 'referreruser', has_signed_in: true)
    creator = FactoryBot.create(:account)
    organisation = FactoryBot.build_stubbed(:organisation)

    sign_in(creator)
    visit "/invite/#{referrer.id}"
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
    visit "/invite/#{account.id}"
    fill_in 'Organisation name', with: organisation.name
    fill_in 'URL', with: organisation.slug
    click_button 'Save and continue'

    saved_organisation = Organisation.find_by(slug: organisation.slug)
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
