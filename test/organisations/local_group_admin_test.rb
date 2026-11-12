require_relative '../test_config'

# Editing a local group, adding and following it, who may do either, and who joins it by where they live
class OrganisationsLocalGroupAdminTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # A square around the factory's group in Stockholm, larger than it
  WIDER_AREA = { type: 'Polygon', coordinates: [[[18.0, 59.3], [18.1, 59.3], [18.1, 59.35], [18.0, 59.35], [18.0, 59.3]]] }.freeze
  INSIDE = [18.068, 59.325].freeze
  OUTSIDE = [-0.12, 51.5].freeze

  # @local_group in @organisation, whose owner (@account) is an organisation admin and the group's creator
  def create_local_group(**attrs)
    create_organisation
    @local_group = FactoryBot.create(:local_group, organisation: @organisation, **attrs)
  end

  def group_admin
    account = FactoryBot.create(:account)
    @local_group.local_groupships.create!(account: account).set(admin: true)
    account
  end

  def follower(local_group = @local_group, **attrs)
    account = FactoryBot.create(:account)
    local_group.local_groupships.create!(account: account, **attrs)
    account
  end

  def assert_redirected_to(path)
    assert last_response.redirect?, "Expected a redirect to #{path}, got #{last_response.status}"
    assert_equal path, URI(last_response.location).path
  end

  def map_count(local_group)
    get '/map', local_group_id: local_group.id, west: -180, south: -90, east: 180, north: 90
    assert last_response.ok?
    JSON.parse(last_response.body)['cells'].sum { |cell| cell['count'] }
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # In the browser
  # ═══════════════════════════════════════════════════════════════════════════

  test "a group admin who isn't an organisation admin edits the group's name and area, and hides its member map" do
    create_local_group
    admin = group_admin
    refute Organisation.admin?(@organisation, admin)

    sign_in(admin)
    visit @local_group.path
    assert page.has_css? '#map-container'
    visit "#{@local_group.path}/edit"
    fill_in 'Name', with: 'Södermalm'
    fill_in 'Geometry', with: WIDER_AREA.to_json
    check 'Hide member map'
    click_button 'Update local group'
    assert page.has_content? 'The local group was saved'
    assert page.has_content? 'Södermalm'
    assert page.has_no_css? '#map-container'

    @local_group.reload
    assert_equal 'Södermalm', @local_group.name
    assert @local_group.hide_members?
    assert_equal JSON.parse(WIDER_AREA.to_json), @local_group.area
    assert_equal [WIDER_AREA[:coordinates]], @local_group.polygons.map(&:coordinates)
  end

  test 'an admin adds a follower by email, who also follows the organisation, and adding them again only warns' do
    create_local_group
    sign_in(@account)
    visit "#{@local_group.path}/followers"
    click_link 'Add a follower'
    fill_in 'email', with: 'newcomer@example.com'
    click_button 'Add follower'
    assert page.has_content? 'newcomer'

    newcomer = Account.find_by(email: 'newcomer@example.com')
    assert newcomer
    refute @local_group.local_groupships.find_by(account: newcomer).unsubscribed?
    refute @organisation.organisationships.find_by(account: newcomer).unsubscribed?

    click_link 'Add a follower'
    fill_in 'email', with: 'Newcomer@example.com '
    click_button 'Add follower'
    assert page.has_content? 'That person is already following the local group'
    assert_equal 1, @local_group.local_groupships.and(account: newcomer).count
  end

  test 'someone follows the group from its page, then hides it from their profile and shows it again' do
    create_local_group
    person = FactoryBot.create(:account)
    sign_in(person)
    visit @local_group.path
    click_link 'Follow'
    assert page.has_link? 'Showing on your profile'
    local_groupship = @local_group.local_groupships.find_by(account: person)
    refute local_groupship.unsubscribed?

    click_link 'Showing on your profile'
    assert page.has_link? 'Not showing on your profile'
    assert local_groupship.reload.hide_membership?

    click_link 'Not showing on your profile'
    assert page.has_link? 'Showing on your profile'
    refute local_groupship.reload.hide_membership?
  end

  test 'an admin chooses whether they receive feedback' do
    create_local_group
    local_groupship = @local_group.local_groupships.find_by(account: @account)

    sign_in(@account)
    visit @local_group.path
    click_link 'Not receiving feedback'
    assert page.has_link? 'Receiving feedback'
    assert local_groupship.reload.receive_feedback?

    click_link 'Receiving feedback'
    assert page.has_link? 'Not receiving feedback'
    refute local_groupship.reload.receive_feedback?
  end

  test "a follower unsubscribes from the group's emails and stays a follower" do
    create_local_group
    person = follower
    sign_in(person)
    visit "#{@local_group.path}/unsubscribe"
    click_button 'Yes, unsubscribe'
    assert page.has_content? "You were unsubscribed from #{@local_group.name}"
    assert @local_group.local_groupships.find_by(account: person).unsubscribed?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Editing, through Rack
  # ═══════════════════════════════════════════════════════════════════════════

  test "followers, another group's admin, another organisation's admin and people signed out can't edit the group" do
    create_local_group
    name = @local_group.name
    other_group = FactoryBot.create(:local_group, organisation: @organisation, account: FactoryBot.create(:account))
    other_organisation = FactoryBot.create(:organisation)

    [follower, other_group.account, other_organisation.account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get "#{@local_group.path}/edit"
      assert_redirected_to @local_group.path
      post "#{@local_group.path}/edit", local_group: { name: 'Taken over' }
      assert_redirected_to @local_group.path
    end
    assert_equal name, @local_group.reload.name

    # Under its own organisation's URL, another organisation's admin finds no such group
    sign_in_with_rack(other_organisation.account)
    get "/o/#{other_organisation.slug}/lg/#{@local_group.slug}/edit"
    assert_equal 404, last_response.status
    post "/o/#{other_organisation.slug}/lg/#{@local_group.slug}/edit", local_group: { name: 'Taken over' }
    assert_equal 404, last_response.status
    assert_equal name, @local_group.reload.name
  end

  test 'organisation admins who are not group admins, and group admins, can edit the group' do
    create_local_group
    organisation_admin = FactoryBot.create(:account, location: nil) # so following the organisation doesn't make them follow the group
    @organisation.organisationships.create!(account: organisation_admin).set(admin: true)
    refute @local_group.local_groupships.find_by(account: organisation_admin)

    { organisation_admin => 'Renamed by the organisation', group_admin => 'Renamed by the group' }.each do |account, name|
      sign_in_with_rack(account)
      get "#{@local_group.path}/edit"
      assert last_response.ok?
      post "#{@local_group.path}/edit", local_group: { name: name }
      assert_redirected_to @local_group.path
      assert_equal name, @local_group.reload.name
    end
  end

  test "a forged form can't move the group to another organisation, change its creator or set its area apart from its geometry" do
    create_local_group
    other_organisation = FactoryBot.create(:organisation)
    area = @local_group.area
    sign_in_with_rack(group_admin)

    post "#{@local_group.path}/edit", local_group: {
      name: 'Renamed',
      organisation_id: other_organisation.id,
      account_id: other_organisation.account.id,
      area: { type: 'Polygon', coordinates: WIDER_AREA[:coordinates] }
    }
    assert_redirected_to @local_group.path

    @local_group.reload
    assert_equal 'Renamed', @local_group.name
    assert_equal @organisation, @local_group.organisation
    assert_equal @account, @local_group.account
    assert_equal area, @local_group.area
    assert_empty other_organisation.local_groups
  end

  test 'an invalid edit shows the form again at the saved URL and changes nothing' do
    create_local_group
    slug = @local_group.slug
    sign_in_with_rack(@account)
    post "#{@local_group.path}/edit", local_group: { name: 'Renamed', slug: 'Not a slug!' }
    assert last_response.ok?
    assert_includes last_response.body, 'There was an error saving the local group'
    assert_includes last_response.body, %(action="/o/#{@organisation.slug}/lg/#{slug}/edit")
    @local_group.reload
    assert_equal slug, @local_group.slug
    refute_equal 'Renamed', @local_group.name
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Followers, through Rack
  # ═══════════════════════════════════════════════════════════════════════════

  test "followers and another group's admin can't add followers or choose to receive feedback" do
    create_local_group
    other_group = FactoryBot.create(:local_group, organisation: @organisation, account: FactoryBot.create(:account))
    person = follower
    other_admin = other_group.account
    # The other group's admin also follows this group, so has a membership receive_feedback could change
    other_admins_membership = @local_group.local_groupships.create!(account: other_admin)

    [person, other_admin].each do |account|
      sign_in_with_rack(account)
      assert_no_difference -> { Account.count } do
        post "#{@local_group.path}/add_follower", email: 'newcomer@example.com'
      end
      assert_redirected_to @local_group.path
      post "#{@local_group.path}/receive_feedback/1"
      assert_redirected_to @local_group.path
    end
    assert_equal 3, @local_group.local_groupships.count
    refute @local_group.local_groupships.find_by(account: person).receive_feedback?
    refute other_admins_membership.reload.receive_feedback?
  end

  test 'an admin chooses receiving feedback for themselves only, and one who does not follow the group has nothing to choose' do
    create_local_group
    other_admin = group_admin
    own = @local_group.local_groupships.find_by(account: @account)
    others = @local_group.local_groupships.find_by(account: other_admin)

    sign_in_with_rack(@account)
    post "#{@local_group.path}/receive_feedback/1", account_id: other_admin.id
    assert own.reload.receive_feedback?
    refute others.reload.receive_feedback?

    organisation_admin = FactoryBot.create(:account, location: nil) # so following the organisation doesn't make them follow the group
    @organisation.organisationships.create!(account: organisation_admin).set(admin: true)
    sign_in_with_rack(organisation_admin)
    post "#{@local_group.path}/receive_feedback/1"
    assert_equal 404, last_response.status
    assert_nil @local_group.local_groupships.find_by(account: organisation_admin)
  end

  test "people follow the group with or without its emails and leave it, but an admin can't leave" do
    create_local_group
    person = FactoryBot.create(:account)
    sign_in_with_rack(person)

    post "#{@local_group.path}/local_groupship", f: 'follow_without_subscribing'
    assert_redirected_to @local_group.path
    assert @local_group.local_groupships.find_by(account: person).unsubscribed?
    post "#{@local_group.path}/local_groupship", f: 'follow_and_subscribe'
    refute @local_group.local_groupships.find_by(account: person).unsubscribed?
    assert_equal 1, @local_group.local_groupships.and(account: person).count

    get "#{@local_group.path}/local_groupship", { membership_toggle: '1' }, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
    assert last_response.ok?
    assert_includes last_response.body, 'Showing on your profile'
    get "#{@local_group.path}/local_groupship"
    assert_redirected_to @local_group.path

    post "#{@local_group.path}/local_groupship", f: 'not_following'
    assert_nil @local_group.local_groupships.find_by(account: person)

    sign_in_with_rack(@account)
    post "#{@local_group.path}/local_groupship", f: 'not_following'
    assert @local_group.local_groupships.find_by(account: @account)
  end

  test 'following, hiding membership and unsubscribing need signing in' do
    create_local_group
    %w[local_groupship hide_membership show_membership unsubscribe].each do |action|
      post "#{@local_group.path}/#{action}", f: 'follow_and_subscribe'
      assert_redirected_to '/accounts/new'
    end
    get "#{@local_group.path}/unsubscribe"
    assert_redirected_to '/accounts/new'
    assert_equal 1, @local_group.local_groupships.count
  end

  test "hiding and showing membership needs following, and changes only one's own" do
    create_local_group
    person = follower
    other = follower
    own = @local_group.local_groupships.find_by(account: person)
    others = @local_group.local_groupships.find_by(account: other)

    sign_in_with_rack(FactoryBot.create(:account))
    post "#{@local_group.path}/hide_membership"
    assert_equal 404, last_response.status
    post "#{@local_group.path}/show_membership"
    assert_equal 404, last_response.status

    sign_in_with_rack(person)
    post "#{@local_group.path}/hide_membership", account_id: other.id
    assert own.reload.hide_membership?
    refute others.reload.hide_membership?
    post "#{@local_group.path}/show_membership"
    refute own.reload.hide_membership?
  end

  test "an admin of another group can't change a membership of this group under their own group's URL" do
    create_local_group
    person = follower
    local_groupship = @local_group.local_groupships.find_by(account: person)
    other_group = FactoryBot.create(:local_group, organisation: @organisation, account: FactoryBot.create(:account))
    sign_in_with_rack(other_group.account)

    get "#{other_group.path}/subscribed/#{local_groupship.id}"
    assert_equal 404, last_response.status
    post "#{other_group.path}/subscribed/#{local_groupship.id}"
    assert_equal 404, last_response.status
    refute local_groupship.reload.unsubscribed?

    post "#{other_group.path}/local_groupships/unadmin", account_id: @account.id
    assert_equal 404, last_response.status
    assert @local_group.local_groupships.find_by(account: @account).admin?

    post "/local_groupships/#{local_groupship.id}/destroy"
    assert_redirected_to @local_group.path
    assert local_groupship.reload
  end

  test "an admin turns a follower's emails off and on" do
    create_local_group
    local_groupship = @local_group.local_groupships.find_by(account: follower)
    sign_in_with_rack(@account)

    post "#{@local_group.path}/subscribed/#{local_groupship.id}"
    assert last_response.ok?
    assert local_groupship.reload.unsubscribed?
    post "#{@local_group.path}/subscribed/#{local_groupship.id}", subscribed: '1'
    refute local_groupship.reload.unsubscribed?
  end

  test "the group's map counts only the followers who show their membership" do
    create_local_group
    @account.set(coordinates: nil, map_hex: nil) # the group's creator, so only the followers below are on the map
    shown = follower
    follower(hide_membership: true)
    assert_equal 1, map_count(@local_group)

    @local_group.local_groupships.find_by(account: shown).set(hide_membership: true)
    assert_equal 0, map_count(@local_group)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Joining by where one lives
  # ═══════════════════════════════════════════════════════════════════════════

  test "people who follow the organisation and live in the group's area join it, with its emails, and people outside don't" do
    covers 'organisations/followers-join-local-groups@336869'
    create_local_group
    inside, outside = Array.new(2) { FactoryBot.create(:account) }
    no_location = FactoryBot.create(:account, location: nil)
    inside.set(coordinates: INSIDE)
    outside.set(coordinates: OUTSIDE)

    [inside, outside, no_location].each { |account| @organisation.organisationships.create!(account: account, skip_welcome: true) }

    local_groupship = @local_group.local_groupships.find_by(account: inside)
    assert local_groupship
    refute local_groupship.unsubscribed?
    assert_nil @local_group.local_groupships.find_by(account: outside)
    assert_nil @local_group.local_groupships.find_by(account: no_location)
  end

  test "a new group takes in the organisation's followers in its area, and not those outside it or another organisation's" do
    create_organisation
    inside, outside = Array.new(2) { FactoryBot.create(:account) }
    inside.set(coordinates: INSIDE)
    outside.set(coordinates: OUTSIDE)
    [inside, outside].each { |account| @organisation.organisationships.create!(account: account, skip_welcome: true) }
    elsewhere = FactoryBot.create(:account)
    elsewhere.set(coordinates: INSIDE)
    FactoryBot.create(:organisation).organisationships.create!(account: elsewhere, skip_welcome: true)

    local_group = FactoryBot.create(:local_group, organisation: @organisation)
    Delayed::Job.and(handler: /add_organisation_members_within/).each(&:invoke_job)

    assert local_group.local_groupships.find_by(account: inside)
    assert_nil local_group.local_groupships.find_by(account: outside)
    assert_nil local_group.local_groupships.find_by(account: elsewhere)
  end
end
