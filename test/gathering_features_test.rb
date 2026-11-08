require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# Each gathering feature, used in the browser as its admin or a member would
class GatheringFeaturesTest < ActiveSupport::TestCase
  include Capybara::DSL

  # A sign-in code works once, so signing someone in again needs a new one
  def sign_in_again(account)
    account.unset(:sign_in_code_nonce, :sign_in_code_expires_at, :sign_in_code_digest)
    sign_in(account)
  end

  def create_member(name: 'Member Person')
    FactoryBot.create(:account, name: name).tap { |account| @gathering.memberships.create!(account: account) }
  end

  # Links that remove something ask in a popover first, whose button is named after the link
  def click_link_and_confirm(label)
    click_link label
    within('.popover') { click_button label }
  end

  def gathering_path(path = '')
    "/g/#{@gathering.slug}#{path}"
  end

  test "a gathering's pages load for its admin" do
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

  test 'applying, and an admin proposing and accepting the application' do
    create_gathering(privacy: 'closed')
    applicant = FactoryBot.create(:account, name: 'Keen Applicant')
    sign_in(applicant)
    visit gathering_path('/apply')
    click_button 'Apply'
    assert page.has_current_path?(gathering_path('/apply'), ignore_query: true)
    assert @gathering.mapplications.find_by(account: applicant)

    sign_in_again(@account)
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
end
