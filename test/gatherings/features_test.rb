require_relative '../test_config'

# Each gathering feature, used in the browser as its admin or a member would. What people can't do, and the limits on
# who gets in and what fills up, are in rules_test.rb
class GatheringFeaturesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # A file the page would download, as text, fetched in the signed-in browser
  def download(path)
    page.evaluate_async_script('fetch(arguments[0]).then(r => r.text()).then(arguments[1])', path)
  end

  test "a gathering's pages load for its admin" do
    covers_route 'GET /g/:slug'
    covers_route 'GET /g/:slug/edit'
    covers_route 'GET /g/:slug/members'
    covers_route 'GET /g/:slug/applications'
    covers_route 'GET /g/:slug/options'
    covers_route 'GET /g/:slug/teams'
    covers_route 'GET /g/:slug/rotas'
    covers_route 'GET /g/:slug/timetables'
    covers_route 'GET /g/:slug/budget'
    covers_route 'GET /g/:slug/payments'
    covers_route 'GET /g/:slug/inventory'
    create_gathering(privacy: 'open')
    sign_in(@account)
    ['', '/edit', '/members', '/applications', '/options', '/teams', '/rotas', '/timetables', '/budget', '/payments', '/inventory'].each do |path|
      visit gathering_path(path)
      assert page.has_content?(@gathering.name), path
    end
  end

  test 'an admin adds a member and makes them an admin' do
    create_gathering(privacy: 'open')
    sign_in(@account)
    visit gathering_path('/members')
    click_link 'Add member'
    fill_in 'Email', with: 'added.person@example.com'
    click_button 'Add member'
    assert page.has_content? 'added.person'
    membership = @gathering.memberships.find_by(account: Account.find_by(email: 'added.person@example.com'))

    within("[data-pagelet-url='#{gathering_path("/membership_row/#{membership.id}")}']") { click_link 'Make admin' }
    assert page.has_link? 'Unadmin'
    assert membership.reload.admin
    within("[data-pagelet-url='#{gathering_path("/membership_row/#{membership.id}")}']") { click_link 'Unadmin' }
    assert page.has_link? 'Make admin'
    refute membership.reload.admin
  end

  test 'an admin filters the members list' do
    covers 'gatherings/member-filters@f9ffca'
    create_gathering(privacy: 'open')
    create_member(name: 'Wendy Woman', gender: 'Woman')
    create_member(name: 'Manfred Man', gender: 'Man')
    sign_in(@account)
    visit gathering_path('/members')
    assert page.has_content? 'Manfred Man'

    select 'Women (1)', from: 'gender'
    assert page.has_select? 'gender', selected: 'Women (1)'
    assert page.has_content? 'Wendy Woman'
    assert page.has_no_content? 'Manfred Man'

    check 'admin'
    assert page.has_checked_field? 'admin'
    assert page.has_no_content? 'Wendy Woman'

    select 'Gender', from: 'gender'
    assert page.has_select? 'gender', selected: 'Gender'
    assert page.has_content? @account.name
    assert page.has_no_content? 'Manfred Man'
  end

  test 'applying, and an admin proposing and accepting the application' do
    create_gathering(privacy: 'closed')
    applicant = FactoryBot.create(:account, name: 'Keen Applicant')
    sign_in(applicant)
    visit gathering_path('/apply')
    click_button 'Apply'
    assert page.has_current_path?(gathering_path('/apply'), ignore_query: true)
    assert @gathering.mapplications.find_by(account: applicant)

    sign_in(@account)
    visit gathering_path('/applications')
    assert page.has_content? 'Keen Applicant'
    click_link 'Propose'
    click_button 'Submit'
    assert page.has_link? 'Unpropose'
    click_link 'Accept'
    # Back on the applications, now without theirs
    assert page.has_content? 'Non-members can apply via'
    assert page.has_no_link? 'Accept'
    assert @gathering.memberships.find_by(account: applicant)
  end

  test 'adding an option, and a member joining and leaving it' do
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(@account)
    visit gathering_path('/options')
    click_link 'Add an option'
    within('#add-option') do
      fill_in 'Name', with: 'Camping'
      click_button 'Create option'
    end
    assert page.has_content? 'Camping'

    sign_in(member)
    visit gathering_path('/options')
    click_link 'Join'
    assert page.has_link? 'Leave'
    assert @gathering.optionships.find_by(account: member)
    click_link_and_confirm 'Leave'
    assert page.has_link? 'Join'
    assert_nil @gathering.optionships.find_by(account: member)
  end

  test 'creating a team, and a member joining and leaving it' do
    covers_route 'GET /g/:slug/teams/new'
    covers_route 'POST /g/:slug/teams/new'
    covers_route 'POST /g/:slug/teamships/create'
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(@account)
    visit gathering_path('/teams/new')
    fill_in 'Name', with: 'Kitchen'
    click_button 'Create team'
    assert page.has_content? 'Kitchen'
    team = @gathering.teams.find_by(name: 'Kitchen')

    sign_in(member)
    visit gathering_path("/teams/#{team.id}")
    click_link 'Join'
    assert page.has_link? 'Leave team'
    assert team.teamships.find_by(account: member)
    click_link_and_confirm 'Leave team'
    assert page.has_link? 'Join'
    assert_nil team.teamships.find_by(account: member)
  end

  test "a member turns a team's email notifications back on from their notification settings" do
    covers_route 'GET /accounts/subscriptions'
    covers_route 'GET /g/:slug/teamships/:id/subscribe'
    covers_route 'POST /g/:slug/teamships/:id/set_subscribe'
    create_gathering(privacy: 'open')
    team = @gathering.teams.create!(name: 'Kitchen', account: @account)
    member = create_member
    teamship = team.teamships.create!(account: member, gathering: @gathering, unsubscribed: true)
    sign_in(member)
    visit '/accounts/subscriptions'
    # Members are also in the gathering's General team
    click_link '2 teams'
    kitchen = find('.subscription-child', text: 'Kitchen')
    kitchen.click_link 'Email notifications off'
    assert kitchen.has_link? 'Email notifications on'
    refute teamship.reload.unsubscribed
  end

  test 'listing an expense and marking it reimbursed' do
    create_gathering(privacy: 'open')
    sign_in(@account)
    visit gathering_path('/budget')
    click_link 'List expense'
    within('#add-spend') do
      fill_in 'Item', with: 'Vegetables'
      fill_in 'Cost', with: '30'
      click_button 'Create spend'
    end
    assert page.has_content? 'Vegetables'
    spend = @gathering.spends.find_by(item: 'Vegetables')

    check "spend-#{spend.id}-reimbursed"
    assert page.has_checked_field? "spend-#{spend.id}-reimbursed"
    assert spend.reload.reimbursed
  end

  test 'creating a rota with roles and slots, and a member signing up for a shift' do
    covers 'gatherings/video-shift-signup@8c93ae'
    covers_route 'POST /g/:slug/rslots/create'
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(@account)
    visit gathering_path('/rotas/new')
    fill_in 'Name', with: 'Kitchen'
    click_button 'Create rota'
    assert page.has_field? placeholder: 'New role'
    rota = @gathering.rotas.find_by(name: 'Kitchen')

    find_field(placeholder: 'New role').fill_in(with: 'Cook').send_keys(:enter)
    assert page.has_link? 'Cook'
    find_field(placeholder: 'New slot').fill_in(with: 'Morning').send_keys(:enter)
    assert page.has_link? 'Morning'

    sign_in(member)
    visit gathering_path("/rotas/#{rota.id}")
    find("a[aria-label='Sign up']").click
    assert page.has_css? "img[alt='Member Person']"
    assert rota.shifts.find_by(account: member)
  end

  test 'creating a timetable, and a member proposing an activity and showing interest' do
    covers_route 'GET /g/:slug/tactivities/:id/attendees'
    covers_route 'POST /g/:slug/spaces/create'
    covers_route 'POST /g/:slug/tactivities/:id/attend'
    covers_route 'POST /g/:slug/tactivities/create'
    covers_route 'POST /g/:slug/tslots/create'
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(@account)
    visit gathering_path('/timetables/new')
    fill_in 'Name', with: 'Workshops'
    click_button 'Create timetable'
    assert page.has_field? placeholder: 'New space'
    timetable = @gathering.timetables.find_by(name: 'Workshops')

    find_field(placeholder: 'New space').fill_in(with: 'Barn').send_keys(:enter)
    assert page.has_content? 'Barn'
    find_field(placeholder: 'New slot').fill_in(with: 'Saturday morning').send_keys(:enter)
    assert page.has_content? 'Saturday morning'

    sign_in(member)
    visit gathering_path("/timetables/#{timetable.id}")
    click_link 'Propose an activity'
    within('#propose-activity') do
      fill_in 'Activity name', with: 'Yoga'
      click_button 'Create activity'
    end
    assert page.has_content? 'Yoga'
    tactivity = timetable.tactivities.find_by(name: 'Yoga')

    click_link 'Interested'
    assert page.has_link? 'No longer interested'
    assert tactivity.attendances.find_by(account: member)
  end

  test 'listing an item, and choosing who brings it' do
    covers_route 'POST /g/:slug/inventory_items/new'
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(@account)
    visit gathering_path('/inventory')
    click_link 'List item'
    within('#add-inventory-item') do
      fill_in 'Item name', with: 'Tent'
      click_button 'Create inventory item'
    end
    assert page.has_content? 'Tent'
    item = @gathering.inventory_items.find_by(name: 'Tent')

    # Named by its aria-label
    find("select[aria-label='Responsible']").select 'Member Person'
    assert page.has_css? "select[aria-label='Responsible'] option[selected]", text: 'Member Person'
    assert_equal member.id, item.reload.responsible_id
  end

  test 'an admin removes a member' do
    covers_route 'POST /g/:slug/memberships/:id/remove'
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(@account)
    visit gathering_path('/members')
    within("[data-pagelet-url='#{gathering_path("/membership_row/#{@gathering.memberships.find_by(account: member).id}")}']") do
      click_link_and_confirm 'Remove'
    end
    assert page.has_content? 'Add member'
    assert page.has_no_content? 'Member Person'
    assert_nil @gathering.memberships.find_by(account: member)
  end

  test 'an admin deletes an application' do
    covers_route 'POST /g/:slug/mapplications/:id/destroy'
    create_gathering(privacy: 'closed')
    @gathering.mapplications.create!(account: FactoryBot.create(:account, name: 'Keen Applicant'), status: 'pending')
    sign_in(@account)
    visit gathering_path('/applications')
    click_link_and_confirm 'Delete'
    assert page.has_content? 'Non-members can apply via'
    assert page.has_no_content? 'Keen Applicant'
    assert_equal 0, @gathering.mapplications.count
  end

  test 'editing and deleting an option' do
    covers_route 'POST /g/:slug/options/:id/destroy'
    create_gathering(privacy: 'open')
    @gathering.options.create!(name: 'Camping', type: 'Tier', account: @account)
    sign_in(@account)
    visit gathering_path('/options')
    click_link 'Camping'
    within('#modal') do
      fill_in 'Name', with: 'Camping field'
      click_button 'Update option'
    end
    assert page.has_link? 'Camping field'

    click_link 'Camping field'
    within('#modal') { click_link_and_confirm 'Delete' }
    assert page.has_link? 'Add an option'
    assert page.has_no_content? 'Camping field'
    assert_equal 0, @gathering.options.count
  end

  test 'editing and deleting a team' do
    covers_route 'GET /g/:slug/teams'
    covers_route 'GET /g/:slug/teams/:id/edit'
    covers_route 'POST /g/:slug/teams/:id/destroy'
    create_gathering(privacy: 'open')
    team = @gathering.teams.create!(name: 'Kitchen', account: @account)
    sign_in(@account)
    visit gathering_path("/teams/#{team.id}")
    click_link 'Edit team'
    fill_in 'Name', with: 'Kitchen crew'
    click_button 'Update team'
    assert page.has_content? 'Kitchen crew'

    click_link 'Edit team'
    click_link_and_confirm 'Delete'
    assert page.has_content? 'General'
    assert page.has_no_content? 'Kitchen crew'
    assert_nil @gathering.teams.find_by(id: team.id)
  end

  test 'editing and deleting an expense' do
    covers_route 'POST /g/:slug/spends/:id/destroy'
    create_gathering(privacy: 'open')
    @gathering.spends.create!(item: 'Vegetables', amount: 30, team: @gathering.teams.first, account: @account)
    sign_in(@account)
    visit gathering_path('/budget')
    click_link 'Vegetables'
    fill_in 'Item', with: 'Fruit and vegetables'
    click_button 'Update spend'
    assert page.has_link? 'Fruit and vegetables'

    click_link 'Fruit and vegetables'
    click_link_and_confirm 'Delete'
    assert page.has_link? 'List expense'
    assert page.has_no_content? 'Fruit and vegetables'
    assert_equal 0, @gathering.spends.count
  end

  test "editing and deleting a rota and its roles and slots" do
    covers_route 'POST /g/:slug/roles/:id/destroy'
    covers_route 'POST /g/:slug/roles/:id/edit'
    covers_route 'POST /g/:slug/rotas/:id/destroy'
    create_gathering(privacy: 'open')
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    Role.create!(name: 'Cook', rota: rota)
    Rslot.create!(name: 'Morning', rota: rota)
    sign_in(@account)
    visit gathering_path("/rotas/#{rota.id}")

    click_link 'Cook'
    within('#modal') do
      fill_in 'Name', with: 'Head cook'
      click_button 'Update role'
    end
    assert page.has_link? 'Head cook'
    click_link 'Morning'
    within('#modal') do
      fill_in 'Name', with: 'Early morning'
      click_button 'Update slot'
    end
    assert page.has_link? 'Early morning'

    click_link 'Head cook'
    within('#modal') { click_link_and_confirm 'Delete' }
    assert page.has_link? 'Early morning'
    assert page.has_no_link? 'Head cook'
    click_link 'Early morning'
    within('#modal') { click_link_and_confirm 'Delete' }
    assert page.has_link? 'Edit rota'
    assert page.has_no_link? 'Early morning'

    click_link 'Edit rota'
    fill_in 'Name', with: 'Kitchen shifts'
    click_button 'Update rota'
    assert page.has_content? 'Kitchen shifts'
    click_link 'Edit rota'
    click_link_and_confirm 'Delete'
    assert page.has_current_path?(gathering_path('/rotas'))
    assert_equal 0, @gathering.rotas.count
  end

  test 'editing and deleting a timetable and its activities' do
    covers_route 'GET /g/:slug/timetables'
    covers_route 'POST /g/:slug/tactivities/:id/destroy'
    covers_route 'POST /g/:slug/timetables/:id/destroy'
    create_gathering(privacy: 'open')
    timetable = @gathering.timetables.create!(name: 'Workshops', account: @account)
    timetable.tactivities.create!(name: 'Yoga', account: @account)
    sign_in(@account)
    visit gathering_path("/timetables/#{timetable.id}")

    # The activity's Edit, not the timetable's
    find("a[title='Edit']").click
    fill_in 'Activity name', with: 'Morning yoga'
    click_button 'Update activity'
    assert page.has_content? 'Morning yoga'
    find("a[title='Edit']").click
    click_link_and_confirm 'Delete'
    assert page.has_link? 'Edit timetable'
    assert page.has_no_content? 'Morning yoga'

    click_link 'Edit timetable'
    fill_in 'Name', with: 'Weekend workshops'
    click_button 'Update timetable'
    assert page.has_content? 'Weekend workshops'
    click_link 'Edit timetable'
    click_link_and_confirm 'Delete'
    assert page.has_current_path?(gathering_path('/timetables'))
    assert_equal 0, @gathering.timetables.count
  end

  test 'editing and deleting an item' do
    covers_route 'POST /g/:slug/inventory_items/:id/destroy'
    create_gathering(privacy: 'open')
    @gathering.inventory_items.create!(name: 'Tent', team: @gathering.teams.first, account: @account)
    sign_in(@account)
    visit gathering_path('/inventory')
    click_link 'Tent'
    fill_in 'Item name', with: 'Big tent'
    click_button 'Update inventory item'
    assert page.has_link? 'Big tent'

    click_link 'Big tent'
    click_link_and_confirm 'Delete'
    assert page.has_link? 'List item'
    assert page.has_no_content? 'Big tent'
    assert_equal 0, @gathering.inventory_items.count
  end

  test 'an admin schedules an activity by dragging it into a slot, and unschedules it' do
    covers 'gatherings/video-schedule-activity@396032'
    create_gathering(privacy: 'open')
    timetable = @gathering.timetables.create!(name: 'Workshops', account: @account)
    space = timetable.spaces.create!(name: 'Barn')
    tslot = timetable.tslots.create!(name: 'Saturday morning')
    tactivity = timetable.tactivities.create!(name: 'Yoga', account: @account)
    sign_in(@account)
    visit gathering_path("/timetables/#{timetable.id}")

    find(".tactivity[data-tactivity-id='#{tactivity.id}']").drag_to find(".tactivity-accept[data-tslot-id='#{tslot.id}'][data-space-id='#{space.id}']")
    assert page.has_css? ".tactivity-accept[data-tslot-id='#{tslot.id}'] .tactivity[data-tactivity-id='#{tactivity.id}']"
    assert_equal [tslot.id, space.id], [tactivity.reload.tslot_id, tactivity.space_id]

    visit gathering_path("/timetables/#{timetable.id}")
    click_link_and_confirm 'Unschedule'
    assert page.has_content? 'Unscheduled'
    assert_nil tactivity.reload.tslot_id
  end

  test "the gathering's newsfeed shows what members do" do
    create_gathering(privacy: 'open')
    team = @gathering.teams.create!(name: 'Kitchen', account: @account)
    rota = @gathering.rotas.create!(name: 'Washing up', account: @account)
    Role.create!(name: 'Washer', rota: rota)
    Rslot.create!(name: 'Evening', rota: rota)
    member = create_member
    sign_in(member)
    visit gathering_path("/teams/#{team.id}")
    click_link 'Join'
    assert page.has_link? 'Leave team'
    visit gathering_path("/rotas/#{rota.id}")
    find("a[aria-label='Sign up']").click
    assert page.has_css? "img[alt='Member Person']"

    sign_in(@account)
    visit gathering_path
    assert page.has_content? 'Member Person joined the Kitchen team'
    assert page.has_content? 'Member Person signed up for a Washing up shift'
    assert page.has_content? 'created the rota Washing up'
  end

  test 'members export the member list, and admins the rota, as CSV' do
    covers_route 'GET /g/:slug/rotas/:id'
    create_gathering(privacy: 'open')
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    role = Role.create!(name: 'Cook', rota: rota)
    rslot = Rslot.create!(name: 'Morning', rota: rota)
    member = create_member(email: 'member.person@example.com', phone: '+447700900123')
    Shift.create!(account: member, role: role, rslot: rslot, rota: rota)

    sign_in(member)
    visit gathering_path('/members')
    assert page.has_content? 'Member Person'
    members = download(gathering_path('/members.csv'))
    assert_includes members, 'Member Person'
    assert_includes members, 'member.person@example.com'

    sign_in(@account)
    visit gathering_path("/rotas/#{rota.id}")
    assert page.has_content? 'Kitchen'
    shifts = CSV.parse(download(gathering_path("/rotas/#{rota.id}.csv")))
    assert_equal ['', 'Cook'], shifts.first
    assert_equal ['Morning', 'Member Person +447700900123'], shifts.last
  end

  test 'choosing an option with a cost, and paying for it by card' do
    create_gathering(privacy: 'open', stripe_pk: 'pk_test_gathering', stripe_sk: 'sk_test_gathering', stripe_endpoint_secret: 'whsec_test')
    @gathering.options.create!(name: 'Camping', type: 'Tier', cost: 20, account: @account)
    member = create_member
    sign_in(member)
    visit gathering_path('/options')
    click_link 'Join'
    assert page.has_content? 'You owe £20'

    record_stripe_redirect
    Stripe::Checkout::Session.stub(:create, api_object(id: 'cs_gathering', payment_intent: 'pi_gathering')) do
      click_button 'Pay with card'
      assert has_checkout_session?('cs_gathering')
    end
    payment = @gathering.payments.find_by(session_id: 'cs_gathering')
    assert_equal [20, 'GBP'], [payment.amount, payment.currency]
    refute payment.payment_completed

    # Stripe tells the gathering the checkout is paid
    paid = Stripe::Event.construct_from({ id: 'evt_gathering', type: 'checkout.session.completed', data: { object: { id: 'cs_gathering', payment_status: 'paid' } } })
    Stripe::Webhook.stub(:construct_event, paid) do
      header 'Stripe-Signature', 'sig'
      post gathering_path('/stripe_webhook') # rubocop:disable Dandelion/TestOneParadigm -- Stripe's webhook, a program's request in the member's flow
    end
    assert payment.reload.payment_completed
    assert_equal 20, @gathering.memberships.find_by(account: member).paid

    visit gathering_path('/options')
    assert page.has_content? 'Camping'
    assert page.has_no_content? 'You owe'
  end
end
