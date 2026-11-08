require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# The rules of a gathering, seen in the browser: who can do what, when applications are accepted, how shifts and the
# timetable fill up, what the newsfeed and exports show
class GatheringRulesTest < ActiveSupport::TestCase
  include Capybara::DSL

  def create_member(name: 'Member Person', **attrs)
    FactoryBot.create(:account, name: name, **attrs).tap { |account| @gathering.memberships.create!(account: account) }
  end

  def gathering_path(path = '')
    "/g/#{@gathering.slug}#{path}"
  end

  # A file the page would download, as text, fetched in the signed-in browser
  def download(path)
    page.evaluate_async_script('fetch(arguments[0]).then(r => r.text()).then(arguments[1])', path)
  end

  test 'members see no admin controls, and admin pages turn them away' do
    create_gathering(privacy: 'open')
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    timetable = @gathering.timetables.create!(name: 'Workshops', account: @account)
    create_member(name: 'Other Member')
    @gathering.mapplications.create!(account: FactoryBot.create(:account, name: 'Keen Applicant'), status: 'pending')
    sign_in(create_member)

    visit gathering_path('/members')
    assert page.has_content? 'Other Member'
    assert page.has_no_link? 'Make admin'
    assert page.has_no_link? 'Remove'
    visit gathering_path("/rotas/#{rota.id}")
    assert page.has_content? 'Kitchen'
    assert page.has_no_field? placeholder: 'New role'
    assert page.has_no_link? 'Edit rota'
    visit gathering_path("/timetables/#{timetable.id}")
    assert page.has_link? 'Propose an activity'
    assert page.has_no_field? placeholder: 'New space'
    visit gathering_path('/options')
    assert page.has_link? 'Add an option'
    assert page.has_no_link? 'Add someone to an option'

    # Members see applications, to propose and support people, but only admins decide them
    visit gathering_path('/applications')
    assert page.has_content? 'Keen Applicant'
    assert page.has_link? 'Propose'
    assert page.has_no_link? 'Accept'
    assert page.has_no_link? 'Pause'

    visit gathering_path('/edit')
    assert page.has_current_path?(gathering_path, ignore_query: true)
  end

  test 'people who are not members are sent to join, to apply or away, by how private the gathering is' do
    outsider = FactoryBot.create(:account)
    sign_in(outsider)
    { 'open' => '/join', 'closed' => '/apply' }.each do |privacy, path|
      create_gathering(privacy: privacy)
      visit gathering_path
      assert page.has_current_path?(gathering_path(path), ignore_query: true), privacy
    end
    create_gathering(privacy: 'secret')
    visit gathering_path
    assert page.has_current_path?('/', ignore_query: true)
  end

  test 'an application is accepted straight away when no proposers are needed' do
    create_gathering(privacy: 'closed', fixed_threshold: 0)
    applicant = FactoryBot.create(:account)
    sign_in(applicant)
    visit gathering_path('/apply')
    click_button 'Apply'
    assert page.has_current_path?(gathering_path('/apply?accepted=true'))
    assert @gathering.memberships.find_by(account: applicant)
  end

  test 'a full gathering takes no more members, and a paused application waits' do
    create_gathering(privacy: 'closed', fixed_threshold: 0, member_limit: 1)
    applicant = FactoryBot.create(:account, name: 'Keen Applicant')
    sign_in(applicant)
    visit gathering_path('/apply')
    click_button 'Apply'
    assert page.has_current_path?(gathering_path('/apply?applied=true'))
    assert_nil @gathering.memberships.find_by(account: applicant)

    sign_in(@account)
    visit gathering_path('/applications')
    assert page.has_content? 'Keen Applicant'
    assert page.has_no_link? 'Accept'
    click_link 'Pause'
    # Moved off the applications to the paused ones
    assert page.has_content? 'Non-members can apply via'
    assert page.has_no_content? 'Keen Applicant'
    visit gathering_path('/applications/paused')
    assert page.has_content? 'Keen Applicant'
    assert page.has_link? 'Unpause'
  end

  test "a shift once taken, or marked not needed, can't be signed up for" do
    create_gathering(privacy: 'open')
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    Role.create!(name: 'Cook', rota: rota)
    Rslot.create!(name: 'Morning', rota: rota)
    Rslot.create!(name: 'Evening', rota: rota)
    first = create_member(name: 'First Member')
    second = create_member(name: 'Second Member')

    sign_in(@account)
    visit gathering_path("/rotas/#{rota.id}")
    all("a[aria-label='Mark as not needed']").last.click
    assert page.has_css? "a[aria-label='Not needed: click to reopen']"

    sign_in(first)
    visit gathering_path("/rotas/#{rota.id}")
    assert page.has_css? '.visually-hidden', text: 'Not needed', visible: :all
    assert_equal 1, all("a[aria-label='Sign up']").count
    find("a[aria-label='Sign up']").click
    assert page.has_css? "img[alt='First Member']"

    sign_in(second)
    visit gathering_path("/rotas/#{rota.id}")
    assert page.has_css? "img[alt='First Member']"
    assert page.has_no_css? "a[aria-label='Sign up']"
    assert_nil rota.shifts.find_by(account: second)
  end

  test 'an admin schedules an activity by dragging it into a slot, and unschedules it' do
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

  # Links that remove something ask in a popover first, whose button is named after the link
  def click_link_and_confirm(label)
    click_link label
    page.document.find('.popover').click_button label
  end
end
