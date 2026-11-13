require_relative '../test_config'

# An organisation's smaller routes: following and subscribing to it, its news, its embedded subscribe form, its cached
# counts, its carousels and the old /organisations/:id URLs
class OrganisationRoutesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  XHR = { 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest' }.freeze

  def sent_pmail(subject, to_option: 'everyone')
    pmail = FactoryBot.create(:pmail, organisation: @organisation, subject: subject, to_option: to_option)
    pmail.set(sent_at: Time.now)
    pmail
  end

  test 'someone follows an organisation with email updates, then without, then unfollows it' do
    covers_route 'POST /o/:slug/organisationship'
    create_organisation
    follower = FactoryBot.create(:account)
    sign_in_with_rack(follower)

    post "/o/#{@organisation.slug}/organisationship", f: 'follow_and_subscribe'
    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
    organisationship = follower.organisationships.find_by(organisation: @organisation)
    refute organisationship.unsubscribed

    post "/o/#{@organisation.slug}/organisationship", { f: 'follow_without_subscribing' }, XHR
    assert last_response.ok?
    assert organisationship.reload.unsubscribed

    post "/o/#{@organisation.slug}/organisationship", f: 'not_following'
    assert_nil follower.organisationships.find_by(organisation: @organisation)
  end

  test "an organisation's admin can't unfollow it" do
    create_organisation
    sign_in_with_rack(@account)
    organisationship = @account.organisationships.find_by(organisation: @organisation)
    assert organisationship.admin?

    post "/o/#{@organisation.slug}/organisationship", f: 'not_following'
    assert organisationship.reload
  end

  test "following an organisation changes only one's own organisationship, and needs signing in" do
    create_organisation
    other = FactoryBot.create(:account)
    other_organisationship = other.associate_with_organisation!(@organisation)

    post "/o/#{@organisation.slug}/organisationship", f: 'follow_without_subscribing', account_id: other.id
    assert_equal '/accounts/new', URI(last_response.location).path
    refute other_organisationship.reload.unsubscribed

    sign_in_with_rack(FactoryBot.create(:account))
    post "/o/#{@organisation.slug}/organisationship", f: 'follow_without_subscribing', account_id: other.id
    refute other_organisationship.reload.unsubscribed
    post "/o/#{@organisation.slug}/organisationship", f: 'not_following', account_id: other.id
    assert other_organisationship.reload
  end

  test "the follow button shows how one follows an organisation, and isn't offered to admins as unfollowing" do
    covers_route 'GET /o/:slug/organisationship'
    create_organisation
    get "/o/#{@organisation.slug}/organisationship", {}, XHR
    assert_equal 403, last_response.status

    follower = FactoryBot.create(:account)
    sign_in_with_rack(follower)
    get "/o/#{@organisation.slug}/organisationship", {}, XHR
    assert_includes last_response.body, "organisationship?f=follow_and_subscribe\" data-bs-toggle=\"tooltip\" title=\"Follow this organisation"

    follower.associate_with_organisation!(@organisation)
    get "/o/#{@organisation.slug}/organisationship", {}, XHR
    assert_includes last_response.body, 'Following with email updates'
    assert_includes last_response.body, 'f=not_following'

    sign_in_with_rack(@account)
    get "/o/#{@organisation.slug}/organisationship", {}, XHR
    assert_includes last_response.body, 'Following with email updates'
    refute_includes last_response.body, 'f=not_following'

    get "/o/#{@organisation.slug}/organisationship"
    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
  end

  test "someone subscribes to an organisation through its embedded form" do
    covers_route 'GET /o/:slug/subscribe'
    create_organisation
    visit "/o/#{@organisation.slug}/subscribe"
    # The thanks page has no stylesheet, so doesn't opt in to app.css's view transition, and Chrome reports the aborted
    # transition as a JavaScript error
    page.execute_script("document.head.insertAdjacentHTML('beforeend', '<style>@view-transition { navigation: none }</style>')")
    fill_in 'Name', with: 'Sam Subscriber'
    fill_in 'Email', with: 'sam.subscriber@example.com'
    click_button 'Subscribe'
    assert page.has_current_path?('/accounts/new')

    account = Account.find_by(email: 'sam.subscriber@example.com')
    assert_equal 'Sam Subscriber', account.name
    refute account.organisationships.find_by(organisation: @organisation).unsubscribed
  end

  test "an organisation's news lists its sent emails to everyone, not drafts or those to donors only" do
    covers_route 'GET /o/:slug/news'
    create_organisation
    sent_pmail('Spring newsletter')
    sent_pmail('Thanks, non-donors', to_option: 'not_monthly_donors')
    sent_pmail('Donors only', to_option: 'monthly_donors')
    FactoryBot.create(:pmail, organisation: @organisation, subject: 'Unsent draft', to_option: 'everyone')

    visit "/o/#{@organisation.slug}/news"
    assert page.has_content?('Spring newsletter')
    assert page.has_content?('Thanks, non-donors')
    assert page.has_no_content?('Donors only')
    assert page.has_no_content?('Unsent draft')
  end

  test "an organisation's latest news goes to its most recently sent email to everyone" do
    covers_route 'GET /o/:slug/news/latest'
    create_organisation
    older = sent_pmail('Older news')
    older.set(sent_at: 2.days.ago)
    latest = sent_pmail('Latest news')
    sent_pmail('Donors only', to_option: 'monthly_donors')

    get "/o/#{@organisation.slug}/news/latest"
    assert_equal "/pmails/#{latest.public_id}", URI(last_response.location).path
  end

  test 'an organisation with no news has no latest news' do
    create_organisation
    FactoryBot.create(:pmail, organisation: @organisation, to_option: 'everyone')
    get "/o/#{@organisation.slug}/news/latest"
    assert_equal 404, last_response.status
  end

  test "an organisation's counts are its cached counts, and an organisation that doesn't exist has none" do
    covers_route 'GET /o/:slug/subscribed_accounts_count'
    covers_route 'GET /o/:slug/monthly_donors_count'
    covers_route 'GET /o/:slug/monthly_donations_count'
    create_organisation
    @organisation.set(subscribed_accounts_count: 12, monthly_donors_count: 3, monthly_donations_count: 'GBP 45.00')
    sign_in_with_rack(@account)

    { subscribed_accounts_count: '12', monthly_donors_count: '3', monthly_donations_count: @organisation.reload.monthly_donations_count.to_s }.each do |count, value|
      get "/o/#{@organisation.slug}/#{count}"
      assert last_response.ok?
      assert_equal value, last_response.body
      get "/o/no-such-organisation/#{count}"
      assert_equal 404, last_response.status
    end
  end

  test 'an old /organisations/:id URL redirects to the organisation by slug, keeping the method' do
    covers_route 'POST /organisations/:id/*'
    create_organisation
    get "/organisations/#{@organisation.id}/events?q=x"
    assert_equal 307, last_response.status
    assert_equal "/o/#{@organisation.slug}/events", URI(last_response.location).path
    assert_equal 'q=x', URI(last_response.location).query

    post "/organisations/#{@organisation.id}/organisationship"
    assert_equal 307, last_response.status
    assert_equal "/o/#{@organisation.slug}/organisationship", URI(last_response.location).path

    post "/organisations/#{BSON::ObjectId.new}/organisationship"
    assert_equal 404, last_response.status
  end

  test "an organisation's admin creates, edits and deletes a carousel" do
    covers_route 'GET /o/:slug/carousels/new'
    covers_route 'POST /o/:slug/carousels/new'
    covers_route 'GET /o/:slug/carousels/:carousel_id/edit'
    covers_route 'POST /o/:slug/carousels/:carousel_id/edit'
    covers_route 'POST /o/:slug/carousels/:carousel_id/destroy'
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/carousels"
    click_link 'Create a carousel'
    fill_in 'Name', with: 'Workshops'
    fill_in 'Weeks', with: '4'
    click_button 'Create carousel'
    assert page.has_content?('The carousel was saved.')
    carousel = @organisation.carousels.find_by(name: 'Workshops')
    assert_equal 4, carousel.weeks

    click_link 'Workshops'
    fill_in 'Name', with: 'Weekend workshops'
    check 'Hide carousel'
    click_button 'Update carousel'
    assert page.has_content?('The carousel was saved.')
    assert_equal 'Weekend workshops', carousel.reload.name
    assert carousel.hidden

    click_link 'Weekend workshops'
    click_link_and_confirm 'Delete'
    assert page.has_link?('Create a carousel')
    assert_nil Carousel.find(carousel.id)
  end

  test "a carousel needs a name" do
    create_organisation
    sign_in(@account)
    visit "/o/#{@organisation.slug}/carousels/new"
    click_button 'Create carousel'
    assert page.has_button?('Create carousel')
    assert_equal 0, @organisation.carousels.count
  end

  test "an organisation's admin orders its carousels" do
    covers_route 'POST /o/:slug/carousels/order'
    create_organisation
    first = FactoryBot.create(:carousel, organisation: @organisation, o: 0)
    second = FactoryBot.create(:carousel, organisation: @organisation, o: 1)
    sign_in_with_rack(@account)

    post "/o/#{@organisation.slug}/carousels/order", carousel_ids: [second.id.to_s, first.id.to_s]
    assert last_response.ok?
    assert_equal [1, 0], [first.reload.o, second.reload.o]
  end

  test "someone who isn't an organisation's admin can't make, change, delete or order its carousels" do
    create_organisation
    carousel = FactoryBot.create(:carousel, organisation: @organisation, name: 'Kept', o: 0)
    sign_in_with_rack(FactoryBot.create(:account))

    get "/o/#{@organisation.slug}/carousels/new"
    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path
    post "/o/#{@organisation.slug}/carousels/new", carousel: { name: 'Sneaky' }
    post "/o/#{@organisation.slug}/carousels/#{carousel.id}/edit", carousel: { name: 'Changed' }
    post "/o/#{@organisation.slug}/carousels/order", carousel_ids: [BSON::ObjectId.new.to_s, carousel.id.to_s]
    post "/o/#{@organisation.slug}/carousels/#{carousel.id}/destroy"
    assert_equal "/o/#{@organisation.slug}", URI(last_response.location).path

    assert_equal %w[Kept], @organisation.carousels.pluck(:name)
    assert_equal 0, carousel.reload.o
  end

  test "an organisation's admin can't reach another organisation's carousel through their own" do
    create_organisation
    other_carousel = FactoryBot.create(:carousel, name: 'Theirs', o: 5)
    sign_in_with_rack(@account)

    get "/o/#{@organisation.slug}/carousels/#{other_carousel.id}/edit"
    assert_equal 404, last_response.status
    post "/o/#{@organisation.slug}/carousels/#{other_carousel.id}/edit", carousel: { name: 'Mine now' }
    assert_equal 404, last_response.status
    post "/o/#{@organisation.slug}/carousels/#{other_carousel.id}/destroy"
    assert_equal 404, last_response.status
    post "/o/#{@organisation.slug}/carousels/order", carousel_ids: [other_carousel.id.to_s, BSON::ObjectId.new.to_s]
    assert_equal 404, last_response.status

    other_carousel.reload
    assert_equal ['Theirs', 5], [other_carousel.name, other_carousel.o]
  end
end
