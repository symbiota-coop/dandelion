require_relative '../test_config'

# Routes of a gathering not tested elsewhere: deleting it, a member's email and sidebar settings, finding one's
# gatherings, deleting and reordering timetables' spaces and slots and rotas' roles and slots, adding someone to a shift,
# who selected an option, unsubscribing from a team, a team's budget and withdrawing a verdict on an application
class GatheringRoutesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def create_other_gathering
    @other_account = FactoryBot.create(:account)
    @other_gathering = FactoryBot.create(:gathering, account: @other_account)
  end

  def create_timetable
    @timetable = @gathering.timetables.create!(name: 'Workshops', account: @account)
    @space = @timetable.spaces.create!(name: 'Barn')
    @tslot = @timetable.tslots.create!(name: 'Saturday morning')
    @tactivity = @timetable.tactivities.create!(name: 'Yoga', account: @account, space: @space, tslot: @tslot)
  end

  def create_rota
    @rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    @role = Role.create!(name: 'Cook', rota: @rota)
    @rslot = Rslot.create!(name: 'Morning', rota: @rota)
  end

  # Deleting a gathering

  test 'an admin deletes a gathering from its edit page, taking its memberships and records with it, but keeping its payments' do
    covers_route 'POST /g/:slug/destroy'
    create_gathering(privacy: 'open')
    member = create_member
    payment = Payment.create!(membership: @gathering.memberships.find_by(account: member), amount: 50, currency: 'GBP')
    create_timetable
    create_rota
    Shift.create!(account: member, role: @role, rslot: @rslot, rota: @rota)
    gathering_id = @gathering.id

    sign_in(@account)
    visit gathering_path('/edit')
    click_link_and_confirm 'Delete'
    assert page.has_content? 'The gathering was deleted'
    refute Gathering.find(gathering_id)
    assert_equal 0, Membership.and(gathering_id: gathering_id).count
    [Timetable, Tactivity, Space, Tslot, Rota, Role, Rslot, Shift, Team, Teamship].each do |model|
      assert_equal 0, model.and(gathering_id: gathering_id).count, model.to_s
    end
    payment.reload
    assert_equal [50, member.id], [payment.amount, payment.account_id]
    assert_equal @gathering.name, payment.gathering_name
  end

  test "only a gathering's admins delete it" do
    create_gathering(privacy: 'open')
    member = create_member
    create_other_gathering

    [member, @other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path('/destroy')
      assert last_response.redirect?
    end
    assert Gathering.find(@gathering.id)
    assert @gathering.memberships.find_by(account: member)
  end

  # Email notifications and the sidebar

  test 'a member turns email notifications off and on from the gathering page' do
    covers_route 'GET /g/:slug/subscribe'
    covers_route 'POST /g/:slug/set_subscribe'
    create_gathering(privacy: 'open')
    member = create_member
    membership = @gathering.memberships.find_by(account: member)
    sign_in(member)
    visit gathering_path
    click_link 'Email notifications on'
    assert page.has_link? 'Email notifications off'
    assert membership.reload.unsubscribed

    click_link 'Email notifications off'
    assert page.has_link? 'Email notifications on'
    refute membership.reload.unsubscribed
  end

  test 'turning email notifications back on is for members, and only changes their own' do
    create_gathering(privacy: 'open')
    member = create_member
    membership = @gathering.memberships.find_by(account: member)
    membership.set(unsubscribed: true)
    create_other_gathering
    site_admin = FactoryBot.create(:account, admin: true)

    [@other_account, site_admin, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path('/set_subscribe')
      assert last_response.redirect?
      get gathering_path('/subscribe')
      assert last_response.redirect?
    end
    assert membership.reload.unsubscribed

    sign_in_with_rack(member)
    get gathering_path('/subscribe')
    assert last_response.ok?
    assert_includes last_response.body, 'Email notifications off'
    post gathering_path('/set_subscribe')
    refute membership.reload.unsubscribed
  end

  test 'a member hides a gathering from their sidebar and shows it again' do
    covers_route 'POST /g/:slug/hide_from_sidebar'
    covers_route 'POST /g/:slug/show_in_sidebar'
    create_gathering(privacy: 'open')
    member = create_member
    membership = @gathering.memberships.find_by(account: member)
    sign_in(member)
    visit gathering_path
    click_link 'Showing in sidebar'
    assert page.has_link? 'Hidden from sidebar'
    assert membership.reload.hide_from_sidebar
    visit '/accounts/subscriptions'
    assert page.has_css? '#sidebar-gatherings', visible: :all
    assert page.has_no_css? "#sidebar-gatherings a[href='#{gathering_path}']", visible: :all

    visit gathering_path
    click_link 'Hidden from sidebar'
    assert page.has_link? 'Showing in sidebar'
    refute membership.reload.hide_from_sidebar
    visit '/accounts/subscriptions'
    assert page.has_css? "#sidebar-gatherings a[href='#{gathering_path}']", visible: :all
  end

  test "hiding a gathering from the sidebar is for its members" do
    create_gathering(privacy: 'open')
    create_other_gathering
    [@other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path('/hide_from_sidebar')
      assert last_response.redirect?
      post gathering_path('/show_in_sidebar')
      assert last_response.redirect?
    end
    refute @gathering.memberships.find_by(account: @account).hide_from_sidebar
  end

  # Finding one's gatherings

  test "autocomplete lists only the gatherings one is a member of, secret ones included, and nobody else's" do
    covers_route 'GET /gatherings/autocomplete'
    create_gathering(name: 'Forest Camp', privacy: 'secret', listed: false)
    own_secret = @gathering
    create_gathering(name: 'Forest School', privacy: 'open')
    own_open = @gathering
    create_other_gathering
    others = [
      FactoryBot.create(:gathering, name: 'Forest Retreat', account: @other_account, privacy: 'secret', listed: false),
      FactoryBot.create(:gathering, name: 'Forest Festival', account: @other_account, privacy: 'open')
    ]

    sign_in_with_rack(@account)
    get '/gatherings/autocomplete', q: 'Forest'
    ids = JSON.parse(last_response.body)['results'].map { |result| result['id'] }
    assert_equal [own_secret.id.to_s, own_open.id.to_s].sort, ids.sort

    get '/gatherings/autocomplete', id: others.first.id.to_s
    assert_empty JSON.parse(last_response.body)['results']
    get '/gatherings/autocomplete', id: own_secret.id.to_s
    assert_equal(["Forest Camp (id:#{own_secret.id})"], JSON.parse(last_response.body)['results'].map { |result| result['text'] })

    clear_cookies
    get '/gatherings/autocomplete', q: 'Forest'
    assert last_response.redirect?
  end

  # Timetables' spaces and slots

  test 'an admin deletes a space and a slot, and the activity scheduled in them goes back to Unscheduled' do
    covers_route 'POST /g/:slug/spaces/:id/destroy'
    covers_route 'POST /g/:slug/tslots/:id/destroy'
    create_gathering(privacy: 'open')
    create_timetable
    @timetable.spaces.create!(name: 'Dome')
    dance = @timetable.tactivities.create!(name: 'Dance', account: @account, space: @timetable.spaces.find_by(name: 'Dome'), tslot: @tslot)
    sign_in(@account)
    visit gathering_path("/timetables/#{@timetable.id}")
    assert page.has_css? ".tactivity-accept[data-space-id='#{@space.id}'] .tactivity[data-tactivity-id='#{@tactivity.id}']"

    click_link_and_confirm 'Barn'
    assert page.has_content? 'Unscheduled'
    assert page.has_no_link? 'Barn'
    assert_nil Space.find(@space.id)
    assert_equal [nil, nil], [@tactivity.reload.space_id, @tactivity.tslot_id]

    click_link_and_confirm 'Saturday morning'
    assert page.has_no_link? 'Saturday morning'
    assert_nil Tslot.find(@tslot.id)
    assert_equal [nil, nil], [dance.reload.space_id, dance.tslot_id]
    assert page.has_content? 'Dance'
  end

  test "only a gathering's admins delete its spaces and slots, and not another gathering's" do
    create_gathering(privacy: 'open')
    create_timetable
    member = create_member
    create_other_gathering
    other_timetable = @other_gathering.timetables.create!(name: 'Talks', account: @other_account)
    other_space = other_timetable.spaces.create!(name: 'Cellar')
    other_tslot = other_timetable.tslots.create!(name: 'Sunday')

    [member, @other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path("/spaces/#{@space.id}/destroy")
      assert last_response.redirect?
      post gathering_path("/tslots/#{@tslot.id}/destroy")
      assert last_response.redirect?
    end
    assert Space.find(@space.id)
    assert Tslot.find(@tslot.id)

    sign_in_with_rack(@account)
    post gathering_path("/spaces/#{other_space.id}/destroy")
    assert_equal 404, last_response.status
    post gathering_path("/tslots/#{other_tslot.id}/destroy")
    assert_equal 404, last_response.status
    assert Space.find(other_space.id)
    assert Tslot.find(other_tslot.id)
  end

  test "an admin reorders a timetable's spaces and slots, and ids not in the timetable are ignored" do
    covers_route 'POST /g/:slug/spaces/order'
    covers_route 'POST /g/:slug/tslots/order'
    create_gathering(privacy: 'open')
    create_timetable
    dome = @timetable.spaces.create!(name: 'Dome')
    afternoon = @timetable.tslots.create!(name: 'Saturday afternoon')
    create_other_gathering
    other_timetable = @other_gathering.timetables.create!(name: 'Talks', account: @other_account)
    other_space = other_timetable.spaces.create!(name: 'Cellar')
    other_tslot = other_timetable.tslots.create!(name: 'Sunday')

    sign_in_with_rack(@account)
    post gathering_path('/spaces/order'), timetable_id: @timetable.id, space_ids: [dome.id, other_space.id, @space.id]
    assert last_response.ok?
    assert_equal [0, 2], [dome.reload.o, @space.reload.o]
    assert_equal 0, other_space.reload.o
    post gathering_path('/tslots/order'), timetable_id: @timetable.id, tslot_ids: [other_tslot.id, afternoon.id, @tslot.id]
    assert last_response.ok?
    assert_equal [1, 2], [afternoon.reload.o, @tslot.reload.o]
    assert_equal 0, other_tslot.reload.o

    post gathering_path('/spaces/order'), timetable_id: other_timetable.id, space_ids: [other_space.id]
    assert_equal 404, last_response.status
    post gathering_path('/tslots/order'), timetable_id: other_timetable.id, tslot_ids: [other_tslot.id]
    assert_equal 404, last_response.status
  end

  test "only a gathering's admins reorder its timetables' spaces and slots" do
    create_gathering(privacy: 'open')
    create_timetable
    dome = @timetable.spaces.create!(name: 'Dome')
    afternoon = @timetable.tslots.create!(name: 'Saturday afternoon')
    member = create_member
    create_other_gathering

    [member, @other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path('/spaces/order'), timetable_id: @timetable.id, space_ids: [dome.id, @space.id]
      assert last_response.redirect?
      post gathering_path('/tslots/order'), timetable_id: @timetable.id, tslot_ids: [afternoon.id, @tslot.id]
      assert last_response.redirect?
    end
    assert_equal [0, 1], [@space.reload.o, dome.reload.o]
    assert_equal [0, 1], [@tslot.reload.o, afternoon.reload.o]
  end

  # Rotas

  test 'an admin adds a member to a shift' do
    covers_route 'GET /g/:slug/rotas/:id/create_shift'
    create_gathering(privacy: 'open')
    create_rota
    create_member
    sign_in(@account)
    visit gathering_path("/rotas/#{@rota.id}/create_shift")
    select 'Member Person', from: 'Account'
    select 'Morning', from: 'Slot'
    select 'Cook', from: 'Role'
    click_button 'Assign to shift'
    assert page.has_link? 'Edit rota'
    assert @rota.shifts.find_by(account: Account.find_by(name: 'Member Person'), role: @role, rslot: @rslot)
  end

  test "adding someone else to a shift is for the gathering's admins, and only adds its members" do
    create_gathering(privacy: 'open')
    create_rota
    member = create_member
    create_other_gathering
    other_rota = @other_gathering.rotas.create!(name: 'Bar', account: @other_account)

    [member, @other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get gathering_path("/rotas/#{@rota.id}/create_shift")
      assert last_response.redirect?
      post gathering_path("/rotas/#{@rota.id}/create_shift"), shift: { account_id: member.id, role_id: @role.id, rslot_id: @rslot.id }
      assert last_response.redirect?
    end
    assert_equal 0, @rota.shifts.count

    sign_in_with_rack(@account)
    get gathering_path("/rotas/#{other_rota.id}/create_shift")
    assert_equal 404, last_response.status
    post gathering_path("/rotas/#{@rota.id}/create_shift"), shift: { account_id: @other_account.id, role_id: @role.id, rslot_id: @rslot.id }
    assert_equal 0, @rota.shifts.count
  end

  test "an admin reorders a rota's roles and slots, and ids not in the rota are ignored" do
    covers_route 'POST /g/:slug/roles/order'
    covers_route 'POST /g/:slug/rslots/order'
    create_gathering(privacy: 'open')
    create_rota
    washer = Role.create!(name: 'Washer', rota: @rota)
    evening = Rslot.create!(name: 'Evening', rota: @rota)
    create_other_gathering
    other_rota = @other_gathering.rotas.create!(name: 'Bar', account: @other_account)
    other_role = Role.create!(name: 'Barista', rota: other_rota)
    other_rslot = Rslot.create!(name: 'Night', rota: other_rota)

    sign_in_with_rack(@account)
    post gathering_path('/roles/order'), rota_id: @rota.id, role_ids: [washer.id, other_role.id, @role.id]
    assert last_response.ok?
    assert_equal [0, 2], [washer.reload.o, @role.reload.o]
    assert_equal 0, other_role.reload.o
    post gathering_path('/rslots/order'), rota_id: @rota.id, rslot_ids: [other_rslot.id, evening.id, @rslot.id]
    assert last_response.ok?
    assert_equal [1, 2], [evening.reload.o, @rslot.reload.o]
    assert_equal 0, other_rslot.reload.o

    post gathering_path('/roles/order'), rota_id: other_rota.id, role_ids: [other_role.id]
    assert_equal 404, last_response.status
    post gathering_path('/rslots/order'), rota_id: other_rota.id, rslot_ids: [other_rslot.id]
    assert_equal 404, last_response.status
  end

  test "only a gathering's admins reorder its rotas' roles and slots" do
    create_gathering(privacy: 'open')
    create_rota
    washer = Role.create!(name: 'Washer', rota: @rota)
    evening = Rslot.create!(name: 'Evening', rota: @rota)
    member = create_member
    create_other_gathering

    [member, @other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path('/roles/order'), rota_id: @rota.id, role_ids: [washer.id, @role.id]
      assert last_response.redirect?
      post gathering_path('/rslots/order'), rota_id: @rota.id, rslot_ids: [evening.id, @rslot.id]
      assert last_response.redirect?
    end
    assert_equal [0, 1], [@role.reload.o, washer.reload.o]
    assert_equal [0, 1], [@rslot.reload.o, evening.reload.o]
  end

  # Options

  test 'a member sees who selected an option, and tiers takes them to the options' do
    covers_route 'GET /g/:slug/options/:id'
    covers_route 'GET /g/:slug/tiers'
    create_gathering(privacy: 'open')
    option = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account)
    other = create_member(name: 'Other Person')
    option.optionships.create!(account: other, gathering: @gathering)
    sign_in(create_member)
    visit gathering_path('/tiers')
    assert page.has_content? 'Tent'
    assert page.has_current_path?(gathering_path('/options'))
    click_link '1/∞'
    within('#modal') do
      assert page.has_content? 'People who selected Tent'
      assert page.has_content? 'Other Person'
    end
  end

  test "who selected an option is for the gathering's members, and not another gathering's option" do
    create_gathering(privacy: 'open')
    option = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account)
    option.optionships.create!(account: create_member(name: 'Other Person'), gathering: @gathering)
    create_other_gathering
    other_option = @other_gathering.options.create!(name: 'Secret cabin', type: 'Accommodation', account: @other_account)

    [@other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get gathering_path("/options/#{option.id}")
      assert last_response.redirect?
      refute_includes last_response.body, 'Other Person'
    end

    sign_in_with_rack(@account)
    get gathering_path("/options/#{other_option.id}")
    assert_equal 404, last_response.status
    refute_includes last_response.body, 'Secret cabin'
  end

  # Teams

  test "a team's unsubscribe link unsubscribes the member from their own teamship, or shows the team if they're not in it" do
    covers_route 'GET /g/:slug/teams/:id/unsubscribe'
    create_gathering(privacy: 'open')
    member = create_member
    other = create_member(name: 'Other Person')
    team = @gathering.teams.create!(name: 'Garden', account: @account)
    teamship = team.teamships.create!(account: member, gathering: @gathering)
    other_teamship = team.teamships.create!(account: other, gathering: @gathering)

    sign_in_with_rack(member)
    get gathering_path("/teams/#{team.id}/unsubscribe")
    assert_equal "http://example.org#{gathering_path("/teamships/#{teamship.id}/unsubscribe")}", last_response.location
    follow_redirect!
    assert teamship.reload.unsubscribed
    refute other_teamship.reload.unsubscribed

    sign_in_with_rack(@account)
    get gathering_path("/teams/#{team.id}/unsubscribe")
    assert_equal "http://example.org#{gathering_path("/teams/#{team.id}")}", last_response.location
    refute other_teamship.reload.unsubscribed
  end

  test "a team's unsubscribe link is for the gathering's members, and not another gathering's team" do
    create_gathering(privacy: 'open')
    team = @gathering.teams.create!(name: 'Garden', account: @account)
    create_other_gathering
    other_team = @other_gathering.teams.create!(name: 'Secret garden', account: @other_account)
    other_teamship = other_team.teamships.create!(account: @other_account, gathering: @other_gathering)

    clear_cookies
    get gathering_path("/teams/#{team.id}/unsubscribe")
    assert last_response.redirect?
    refute_includes last_response.location, '/teamships/'

    sign_in_with_rack(@other_account)
    get gathering_path("/teams/#{other_team.id}/unsubscribe")
    assert last_response.redirect?
    refute_includes last_response.location, '/teamships/'

    sign_in_with_rack(@account)
    get gathering_path("/teams/#{other_team.id}/unsubscribe")
    assert_equal 404, last_response.status
    refute other_teamship.reload.unsubscribed
  end

  test "a member sets a team's budget on the budget page" do
    covers_route 'POST /g/:slug/teams/:id/budget'
    create_gathering(privacy: 'open')
    team = @gathering.teams.find_by(name: 'General')
    sign_in(create_member)
    visit gathering_path('/budget')
    find("form[action='#{gathering_path("/teams/#{team.id}/budget")}'] input[name='budget']").fill_in(with: '200')
    find('h2', text: 'Projected outgoings').click
    assert page.has_link? '£200'
    assert_equal 200, team.reload.budget
  end

  test "a team's budget is set by the gathering's members, not anyone else, and not another gathering's" do
    create_gathering(privacy: 'open')
    team = @gathering.teams.find_by(name: 'General')
    create_other_gathering
    other_team = @other_gathering.teams.find_by(name: 'General')

    [@other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path("/teams/#{team.id}/budget"), budget: 500
      assert last_response.redirect?
    end
    assert_nil team.reload.budget

    sign_in_with_rack(@account)
    post gathering_path("/teams/#{other_team.id}/budget"), budget: 500
    assert_equal 404, last_response.status
    assert_nil other_team.reload.budget
  end

  # Verdicts on applications

  test 'a member withdraws their proposal of an applicant' do
    covers_route 'POST /g/:slug/verdicts/:id/destroy'
    create_gathering(privacy: 'closed', fixed_threshold: 2)
    member = create_member
    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account, name: 'Applicant Person'), status: 'pending')
    mapplication.verdicts.create!(account: member, type: 'proposer')
    sign_in(member)
    visit gathering_path('/applications')
    click_link_and_confirm 'Unpropose'
    assert page.has_link? 'Propose'
    refute mapplication.verdicts.find_by(account: member)
  end

  test "only a verdict's author withdraws it, and not through another gathering's URL" do
    create_gathering(privacy: 'closed', fixed_threshold: 2)
    member = create_member
    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    verdict = mapplication.verdicts.create!(account: member, type: 'proposer')
    create_other_gathering
    @other_gathering.memberships.create!(account: member)
    other_mapplication = @other_gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    other_verdict = other_mapplication.verdicts.create!(account: member, type: 'proposer')

    [@account, @other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path("/verdicts/#{verdict.id}/destroy")
      assert_equal 403, last_response.status
    end
    assert Verdict.find(verdict.id)

    sign_in_with_rack(member)
    post gathering_path("/verdicts/#{other_verdict.id}/destroy")
    assert_equal 404, last_response.status
    assert Verdict.find(other_verdict.id)
  end
end
