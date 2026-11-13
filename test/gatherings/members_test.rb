require_relative '../test_config'

# A gathering's members: what its admins set on a membership (admin, paid, invitations, shift points), adding members,
# seeing a member's answers and leaving (though not by a gathering's only admin), and who may do each
class GatheringMembersTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def membership_of(account)
    @gathering.memberships.find_by(account: account)
  end

  def membership_row(membership)
    find("[data-pagelet-url='#{gathering_path("/membership_row/#{membership.id}")}']")
  end

  # The members table's cell whose form posts to the route ending in suffix
  def cell_posting_to(row, suffix)
    row.find(:xpath, ".//td[.//form[substring(@action, string-length(@action) - #{suffix.length - 1}) = '#{suffix}']]")
  end

  # A second gathering, with its own admin and a member, for requests that name its memberships from the first
  def create_other_gathering
    @other_gathering = FactoryBot.create(:gathering, account: FactoryBot.create(:account))
    @other_membership = @other_gathering.memberships.create!(account: FactoryBot.create(:account))
  end

  test 'an admin records what a member paid, their invitations and the shift points they owe' do
    create_gathering(privacy: 'open', enable_shift_worth: true)
    @gathering.rotas.create!(name: 'Kitchen', account: @account)
    membership = membership_of(create_member)
    sign_in(@account)
    visit gathering_path('/members')

    # Paid starts at nothing, shown as a link that opens its field
    paid = cell_posting_to(membership_row(membership), '/paid')
    paid.find('a').click
    paid.fill_in 'paid', with: '50'
    paid.find_field('paid').send_keys(:tab)
    assert membership_row(membership).has_link? '£50'
    assert_equal 50, membership.reload.paid

    invitations = cell_posting_to(membership_row(membership), '/invitations_granted')
    invitations.click_link '0'
    invitations.fill_in 'invitations_granted', with: '3'
    invitations.find_field('invitations_granted').send_keys(:tab)
    assert cell_posting_to(membership_row(membership), '/invitations_granted').has_link? '3'
    assert_equal 3, membership.reload.invitations_granted
    assert_equal 3, membership.invitations_remaining

    shifts = cell_posting_to(membership_row(membership), '/shift_points_required')
    shifts.click_link '?'
    shifts.fill_in 'shift_points_required', with: '2.5'
    shifts.find_field('shift_points_required').send_keys(:tab)
    assert cell_posting_to(membership_row(membership), '/shift_points_required').has_link? '2.5'
    assert_in_delta 2.5, membership.reload.shift_points_required
  end

  test "members can't make anyone an admin, themselves included, nor can anyone signed out or from another gathering" do
    covers_route 'POST /g/:slug/memberships/:id/make_admin'
    create_gathering(privacy: 'open')
    create_other_gathering
    member = create_member
    other = membership_of(create_member(name: 'Other Person'))
    own = membership_of(member)

    sign_in_with_rack(member)
    [own, other].each do |membership|
      post gathering_path("/memberships/#{membership.id}/make_admin")
      assert last_response.redirect?
      refute membership.reload.admin
      assert_nil membership.admin_status_changed_by_id
      refute membership.notifications.find_by(type: 'made_admin')
    end
    refute Gathering.admin?(@gathering, member)

    clear_cookies
    post gathering_path("/memberships/#{other.id}/make_admin")
    assert last_response.redirect?
    refute other.reload.admin

    # An admin of another gathering, through either gathering's address
    sign_in_with_rack(@other_gathering.account)
    post gathering_path("/memberships/#{other.id}/make_admin")
    assert last_response.redirect?
    post "/g/#{@other_gathering.slug}/memberships/#{other.id}/make_admin"
    assert_equal 404, last_response.status
    refute other.reload.admin
  end

  test "an admin can't make a member of another gathering an admin through their own gathering's address" do
    create_gathering(privacy: 'open')
    create_other_gathering
    sign_in_with_rack(@account)
    post gathering_path("/memberships/#{@other_membership.id}/make_admin")
    assert_equal 404, last_response.status
    refute @other_membership.reload.admin
    refute Gathering.admin?(@other_gathering, @other_membership.account)
  end

  test "only a gathering's admins can set what a member paid, their invitations and their shift points" do
    covers_route 'POST /g/:slug/memberships/:id/invitations_granted'
    covers_route 'POST /g/:slug/memberships/:id/paid'
    covers_route 'POST /g/:slug/memberships/:id/shift_points_required'
    create_gathering(privacy: 'open')
    create_other_gathering
    member = create_member
    targets = [membership_of(member), membership_of(create_member(name: 'Other Person'))]
    changes = { 'paid' => 500, 'invitations_granted' => 10, 'shift_points_required' => 0 }

    refused = lambda do |membership|
      before = changes.keys.map { |field| membership.reload.send(field) }
      changes.each do |field, value|
        post gathering_path("/memberships/#{membership.id}/#{field}"), field => value
        assert last_response.redirect?, field
      end
      assert_equal(before, changes.keys.map { |field| membership.reload.send(field) })
    end

    sign_in_with_rack(member)
    targets.each(&refused)
    clear_cookies
    targets.each(&refused)
    sign_in_with_rack(@other_gathering.account)
    targets.each(&refused)

    # This gathering's admin, naming another gathering's membership
    sign_in_with_rack(@account)
    changes.each do |field, value|
      post gathering_path("/memberships/#{@other_membership.id}/#{field}"), field => value
      assert_equal 404, last_response.status, field
    end
    assert_equal([0, nil, nil], changes.keys.map { |field| @other_membership.reload.send(field) })

    # And the same admin, on their own gathering's member
    changes.each do |field, value|
      post gathering_path("/memberships/#{targets.first.id}/#{field}"), field => value
      assert last_response.ok?, field
    end
    targets.first.reload
    assert_equal 500, targets.first.paid
    assert_equal 10, targets.first.invitations_granted
    assert_in_delta 0.0, targets.first.shift_points_required
  end

  test "the gathering's only admin isn't offered leaving, unadmining or removing themselves until there's another admin" do
    covers 'gatherings/only-admin-stays@432957'
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(@account)
    visit gathering_path
    assert page.has_button? 'Leave gathering', disabled: true
    assert page.has_no_link? 'Leave gathering'

    visit gathering_path('/members')
    own_row = membership_row(membership_of(@account))
    assert own_row.has_content? 'Only admin'
    assert own_row.has_no_link? 'Unadmin'
    assert own_row.has_no_link? 'Remove'

    membership_row(membership_of(member)).click_link 'Make admin'
    assert membership_row(membership_of(member)).has_link? 'Unadmin'
    assert membership_row(membership_of(@account)).has_link? 'Unadmin'
    assert membership_row(membership_of(@account)).has_link? 'Remove'

    visit gathering_path
    click_link_and_confirm 'Leave gathering'
    assert page.has_content? "You left #{@gathering.name}"
    assert_nil membership_of(@account)
    assert membership_of(member).admin
  end

  test "the gathering's only admin can't leave, unadmin themselves or be removed, by them or a site admin" do
    covers 'gatherings/only-admin-stays@432957'
    covers_route 'POST /g/:slug/memberships/:id/unadmin'
    create_gathering(privacy: 'open')
    member = create_member
    own = membership_of(@account)
    site_admin = FactoryBot.create(:account, admin: true)

    sign_in_with_rack(@account)
    post gathering_path('/leave')
    assert last_response.redirect?
    follow_redirect!
    assert_includes last_response.body, 'the only admin of'
    assert own.reload
    post gathering_path("/memberships/#{own.id}/unadmin")
    assert last_response.redirect?
    post gathering_path("/memberships/#{own.id}/remove")
    assert last_response.redirect?
    assert own.reload.admin
    refute own.notifications.find_by(type: 'unadmined')

    sign_in_with_rack(site_admin)
    post gathering_path("/memberships/#{own.id}/unadmin")
    post gathering_path("/memberships/#{own.id}/remove")
    assert own.reload.admin
    # A site admin browsing has no membership to leave
    post gathering_path('/leave')
    assert last_response.redirect?
    assert own.reload

    # With a second admin, the first can go
    membership_of(member).set(admin: true)
    sign_in_with_rack(@account)
    post gathering_path("/memberships/#{own.id}/unadmin")
    refute own.reload.admin
    post gathering_path("/memberships/#{membership_of(member).id}/remove")
    assert membership_of(member), 'the only admin left stays'
  end

  test "a value the members table can't take is refused, says why and saves nothing" do
    create_gathering(privacy: 'open', enable_shift_worth: true)
    @gathering.rotas.create!(name: 'Kitchen', account: @account)
    membership = membership_of(create_member)
    sign_in(@account)
    visit gathering_path('/members')

    invitations = cell_posting_to(membership_row(membership), '/invitations_granted')
    invitations.click_link '0'
    invitations.fill_in 'invitations_granted', with: '-1'
    invitations.find_field('invitations_granted').send_keys(:tab)
    assert invitations.has_css? '.invalid-feedback', text: 'Invitations granted must be greater than or equal to 0'
    assert_nil membership.reload.invitations_granted

    # Corrected, it saves
    invitations.fill_in 'invitations_granted', with: '2'
    invitations.find_field('invitations_granted').send_keys(:tab)
    assert cell_posting_to(membership_row(membership), '/invitations_granted').has_link? '2'
    assert_equal 2, membership.reload.invitations_granted
  end

  test 'what a member paid, their invitations and shift points must be numbers of 0 or more, and whole where they count money or people' do
    create_gathering(privacy: 'open')
    membership = membership_of(create_member)
    membership.set(paid: 10, invitations_granted: 2, shift_points_required: 1.5)
    sign_in_with_rack(@account)
    refused = {
      'paid' => ['-5', '2.5', 'lots'],
      'invitations_granted' => ['-1', '1.5', 'some'],
      'shift_points_required' => ['-0.5', 'many', '1e400']
    }
    refused.each do |field, values|
      values.each do |value|
        post gathering_path("/memberships/#{membership.id}/#{field}"), field => value
        assert_equal 422, last_response.status, "#{field}: #{value}"
        assert_match(/#{field.humanize}/i, last_response.body)
      end
    end
    membership.reload
    assert_equal [10, 2, 1.5], [membership.paid, membership.invitations_granted, membership.shift_points_required]

    # Blank clears invitations and shift points back to unset, and paid to nothing
    refused.each_key do |field|
      post gathering_path("/memberships/#{membership.id}/#{field}"), field => ''
      assert last_response.ok?, field
    end
    membership.reload
    assert_equal [0, nil, nil], [membership.paid, membership.invitations_granted, membership.shift_points_required]
  end

  test "members see another member's answers to the joining questions" do
    create_gathering(privacy: 'open')
    create_member(name: 'Answering Person').then { |account| membership_of(account).set(answers: [['Why are you joining?', 'To build the dome']]) }
    sign_in(create_member(name: 'Curious Person'))
    visit gathering_path('/members')
    row = membership_row(membership_of(Account.find_by(name: 'Answering Person')))
    row.find("a[onclick*='/memberships/']").click
    assert page.has_css? '#modal', text: 'To build the dome'
    assert page.has_css? '#modal', text: 'Why are you joining?'
  end

  test "a member's answers are for the gathering's confirmed members, and opened directly go to the members page" do
    covers_route 'GET /g/:slug/memberships/:id'
    create_gathering(privacy: 'open', demand_payment: true)
    create_other_gathering
    answering = create_member(name: 'Answering Person')
    membership = membership_of(answering)
    membership.set(answers: [['Why are you joining?', 'To build the dome']], paid: 10)
    unpaid = create_member(name: 'Unpaid Person')
    path = gathering_path("/memberships/#{membership.id}")

    get path, {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
    assert_equal 403, last_response.status

    [unpaid, @other_gathering.account, FactoryBot.create(:account)].each do |account|
      sign_in_with_rack(account)
      get path, {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
      assert_equal 403, last_response.status, account.name
      assert_not_includes last_response.body, 'To build the dome'
    end

    sign_in_with_rack(answering)
    get path, {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
    assert last_response.ok?
    assert_includes last_response.body, 'To build the dome'

    get path
    assert last_response.redirect?
    assert_equal gathering_path('/members'), URI(last_response.location).path

    # Another gathering's membership, through this gathering's address
    get gathering_path("/memberships/#{@other_membership.id}"), {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
    assert_equal 404, last_response.status
  end

  test 'a member adds someone with their invitations, until they run out' do
    create_gathering(privacy: 'open')
    member = create_member
    membership_of(member).set(invitations_granted: 1)
    sign_in(member)
    visit gathering_path('/members')
    assert page.has_content? '1 invitation remaining'
    click_link 'Add member'
    fill_in 'Email', with: 'invited.person@example.com'
    click_button 'Add member'
    assert page.has_content? 'invited.person'
    invited = Account.find_by(email: 'invited.person@example.com')
    assert membership_of(invited)
    assert_equal member.id, membership_of(invited).added_by_id
    assert_equal 0, membership_of(member).invitations_remaining
    assert page.has_no_link? 'Add member'
  end

  test 'nobody adds members without an invitation left, confirmed membership or being an admin' do
    covers_route 'POST /g/:slug/add_member'
    create_gathering(privacy: 'open')
    create_other_gathering
    member = create_member
    path = gathering_path('/add_member')

    sign_in_with_rack(member)
    post path, email: 'uninvited@example.com'
    assert last_response.redirect?
    follow_redirect!
    assert_includes last_response.body, 'You have run out of invitations'
    assert_nil Account.find_by(email: 'uninvited@example.com')

    # Invitations granted, but not yet paid where payment is demanded
    membership_of(member).set(invitations_granted: 5)
    @gathering.set(demand_payment: true)
    post path, email: 'uninvited@example.com'
    assert last_response.redirect?
    assert_nil Account.find_by(email: 'uninvited@example.com')

    existing = FactoryBot.create(:account)
    [@other_gathering.account, FactoryBot.create(:account)].each do |account|
      sign_in_with_rack(account)
      post path, email: existing.email
      assert last_response.redirect?
    end
    clear_cookies
    post path, email: existing.email
    assert last_response.redirect?
    assert_nil membership_of(existing)
    assert_nil Account.find_by(email: 'uninvited@example.com')
  end

  test "adding someone who's already a member doesn't add them again" do
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(@account)
    visit gathering_path('/members')
    click_link 'Add member'
    fill_in 'Email', with: member.email
    click_button 'Add member'
    assert page.has_content? 'That person is already a member of the gathering'
    assert_equal 1, @gathering.memberships.and(account: member).count
    assert_nil membership_of(member).added_by_id
  end

  test 'a member leaves, giving up their shifts, teams and options, while their payments stay on record' do
    create_gathering(privacy: 'open')
    member = create_member
    membership = membership_of(member)
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    shift = Shift.create!(account: member, role: Role.create!(name: 'Cook', rota: rota), rslot: Rslot.create!(name: 'Morning', rota: rota), rota: rota)
    teamship = @gathering.teams.create!(name: 'Garden', account: @account).teamships.create!(account: member, gathering: @gathering)
    optionship = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account).optionships.create!(account: member, gathering: @gathering)
    payment = Payment.create!(membership: membership, amount: 50, currency: 'GBP')
    assert_equal 2, membership.teamships.count # Garden, and General, which everyone joins

    sign_in(member)
    visit gathering_path
    click_link_and_confirm 'Leave gathering'
    assert page.has_content? "You left #{@gathering.name}"
    assert page.has_current_path?('/', ignore_query: true)

    assert_nil Membership.find(membership.id)
    assert_nil Shift.find(shift.id)
    assert_nil Teamship.find(teamship.id)
    assert_equal 0, Teamship.and(membership_id: membership.id).count
    assert_nil Optionship.find(optionship.id)
    payment.reload
    assert_nil payment.membership_id
    assert_equal member.id, payment.account_id
    assert_equal @gathering.id, payment.gathering_id
    assert_equal 1, @gathering.reload.membership_count
    assert member.notifications_as_notifiable.find_by(type: 'left_gathering')
  end

  test 'only a member can leave, and leaving takes no one else out' do
    covers_route 'POST /g/:slug/leave'
    create_gathering(privacy: 'open')
    member = create_member
    outsider = FactoryBot.create(:account)
    path = gathering_path('/leave')

    clear_cookies
    post path
    assert last_response.redirect?
    sign_in_with_rack(outsider)
    post path
    assert last_response.redirect?
    assert membership_of(member)
    assert membership_of(@account)

    sign_in_with_rack(member)
    post path
    assert_equal '/', URI(last_response.location).path
    assert_nil membership_of(member)
    assert membership_of(@account)
  end
end
