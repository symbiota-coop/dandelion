require_relative '../test_config'

# Creating and editing organisations, referrals, unsubscribing and event lists
class OrganisationsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

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
    covers_route 'GET /invite/:username'
    covers_route 'GET /o/new'
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
    covers_route 'POST /o/new'
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
    covers_route 'GET /o/:slug/unsubscribe'
    create_organisation
    victim = FactoryBot.create(:account)
    victim.organisationships.create!(organisation: @organisation)

    visit "/o/#{@organisation.slug}/unsubscribe?account_id=#{victim.id}"

    assert page.has_current_path?('/accounts/new')
    assert_equal false, victim.organisationships.find_by(organisation: @organisation).unsubscribed
  end

  test 'posting another account_id to organisation unsubscribe unsubscribes only the account signed in' do
    create_organisation
    victim = FactoryBot.create(:account)
    victim_organisationship = victim.organisationships.create!(organisation: @organisation)
    attacker = FactoryBot.create(:account)
    attacker_organisationship = attacker.organisationships.create!(organisation: @organisation)

    post "/o/#{@organisation.slug}/unsubscribe", account_id: victim.id
    assert last_response.redirect?
    assert_equal '/accounts/new', URI(last_response.location).path
    refute victim_organisationship.reload.unsubscribed

    sign_in_with_rack(attacker)
    post "/o/#{@organisation.slug}/unsubscribe", account_id: victim.id
    assert last_response.redirect?
    assert_equal '/accounts/subscriptions', URI(last_response.location).path
    assert attacker_organisationship.reload.unsubscribed
    refute victim_organisationship.reload.unsubscribed
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
    covers_route 'POST /o/:slug/unsubscribe'
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
    covers_route 'POST /o/:slug/organisation_tiers/:organisation_tier_id/edit'
    create_organisation
    organisation_tier = @organisation.organisation_tiers.create!(name: 'Gold', threshold: 100, discount: 10)
    other_organisation = FactoryBot.create(:organisation)

    sign_in_with_rack(@account)
    post "/o/#{@organisation.slug}/organisation_tiers/#{organisation_tier.id}/edit", organisation_tier: { name: 'Gold', threshold: 100, discount: 10, organisation_id: other_organisation.id }

    assert_equal @organisation.id, organisation_tier.reload.organisation_id
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
    assert_equal 2, last_response.body.scan('snap-carousel-item"').length
    assert_equal 2, Fragment.count

    Fragment.all.each { |fragment| fragment.set(value: '<p>cached card</p>') }
    get "/o/#{@organisation.slug}/events?display=grid"
    assert_equal 2, last_response.body.scan('cached card').length
    get "/o/#{@organisation.slug}/carousels/featured"
    assert_equal 2, last_response.body.scan('cached card').length
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
end
