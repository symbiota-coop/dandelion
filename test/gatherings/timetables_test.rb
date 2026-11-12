require_relative '../test_config'

# A gathering's timetables and their activities: who may make and change them, schedule activities and say they're
# interested. Creating, editing and dragging activities in the browser are also in features_test.rb
class GatheringTimetablesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def create_timetable(**attrs)
    @timetable = @gathering.timetables.create!(name: 'Workshops', account: @account, **attrs)
    @space = @timetable.spaces.create!(name: 'Barn')
    @tslot = @timetable.tslots.create!(name: 'Saturday morning')
    @tactivity = @timetable.tactivities.create!(name: 'Yoga', account: @account)
  end

  def create_other_gathering
    @other_account = FactoryBot.create(:account)
    @other_gathering = FactoryBot.create(:gathering, account: @other_account)
  end

  test "an admin schedules an activity from its edit form, and its page shows who's interested" do
    create_gathering(privacy: 'open')
    create_timetable
    member = create_member
    @tactivity.attendances.create!(account: member)
    sign_in(@account)
    visit gathering_path("/tactivities/#{@tactivity.id}/edit")
    select 'Barn', from: 'Space'
    select 'Saturday morning', from: 'Slot'
    click_button 'Update activity'
    assert page.has_css? ".tactivity-accept[data-tslot-id='#{@tslot.id}'] .tactivity[data-tactivity-id='#{@tactivity.id}']"
    assert_equal [@space.id, @tslot.id], [@tactivity.reload.space_id, @tactivity.tslot_id]

    visit gathering_path("/tactivities/#{@tactivity.id}")
    assert page.has_content? 'Yoga'
    assert page.has_content? '1 person interested'
    assert page.has_css? "img[alt='Member Person']"
    assert page.has_link? 'Interested', class: 'btn'
  end

  test 'a member says they are no longer interested in an activity from its page' do
    create_gathering(privacy: 'open')
    create_timetable
    member = create_member
    @tactivity.attendances.create!(account: member)
    sign_in(member)
    visit gathering_path("/tactivities/#{@tactivity.id}")
    click_link 'No longer interested', class: 'btn'
    assert page.has_link? 'Interested', class: 'btn'
    assert_nil @tactivity.attendances.find_by(account: member)
  end

  test "only the gathering's admins make and edit its timetables" do
    create_gathering(privacy: 'open')
    create_timetable
    create_other_gathering
    member = create_member

    [member, @other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get gathering_path('/timetables/new')
      assert last_response.redirect?
      post gathering_path('/timetables/new'), timetable: { name: 'Talks' }
      assert last_response.redirect?
      get gathering_path("/timetables/#{@timetable.id}/edit")
      assert last_response.redirect?
      post gathering_path("/timetables/#{@timetable.id}/edit"), timetable: { name: 'Hijacked' }
      assert last_response.redirect?
    end
    refute @gathering.timetables.find_by(name: 'Talks')
    assert_equal 'Workshops', @timetable.reload.name

    sign_in_with_rack(@account)
    post gathering_path('/timetables/new'), timetable: { name: 'Talks' }
    assert @gathering.timetables.find_by(name: 'Talks')
    post gathering_path("/timetables/#{@timetable.id}/edit"), timetable: { name: 'Weekend workshops' }
    assert_equal 'Weekend workshops', @timetable.reload.name
  end

  test "a gathering's timetable and activity routes don't find another gathering's" do
    create_gathering(privacy: 'open')
    create_timetable
    create_other_gathering
    other_timetable = @other_gathering.timetables.create!(name: 'Secret talks', account: @other_account)
    other_tactivity = other_timetable.tactivities.create!(name: 'Secret session', account: @other_account)
    other_tslot = other_timetable.tslots.create!(name: 'Sunday')
    other_space = other_timetable.spaces.create!(name: 'Cellar')

    sign_in_with_rack(@account)
    get gathering_path("/timetables/#{other_timetable.id}/edit")
    assert_equal 404, last_response.status
    post gathering_path("/timetables/#{other_timetable.id}/edit"), timetable: { name: 'Hijacked' }
    assert_equal 404, last_response.status
    assert_equal 'Secret talks', other_timetable.reload.name
    get gathering_path("/tactivities/#{other_tactivity.id}")
    assert_equal 404, last_response.status
    refute_includes last_response.body, 'Secret session'
    get gathering_path("/tactivities/#{other_tactivity.id}/edit")
    assert_equal 404, last_response.status
    post gathering_path("/tactivities/#{other_tactivity.id}/edit"), tactivity: { name: 'Hijacked' }
    assert_equal 404, last_response.status
    [
      ["/tactivities/#{other_tactivity.id}/schedule", { tslot_id: other_tslot.id, space_id: other_space.id }],
      ["/tactivities/#{other_tactivity.id}/unschedule", {}],
      ["/tactivities/#{other_tactivity.id}/unattend", {}]
    ].each do |path, params|
      post gathering_path(path), params
      assert_equal 404, last_response.status, path
    end
    assert_equal 'Secret session', other_tactivity.reload.name
    assert_nil other_tactivity.tslot_id
  end

  test "nobody outside the gathering sees, edits, schedules or unschedules its activities" do
    create_gathering(privacy: 'open')
    create_timetable(scheduling_by_all: true)
    create_other_gathering

    [@other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get gathering_path("/tactivities/#{@tactivity.id}")
      assert last_response.redirect?
      get gathering_path("/tactivities/#{@tactivity.id}/edit")
      assert last_response.redirect?
      post gathering_path("/tactivities/#{@tactivity.id}/edit"), tactivity: { name: 'Hijacked' }
      assert last_response.redirect?
      post gathering_path("/tactivities/#{@tactivity.id}/schedule"), tslot_id: @tslot.id, space_id: @space.id
      assert last_response.redirect?
      assert_nil @tactivity.reload.tslot_id
    end
    @tactivity.update_attributes!(tslot: @tslot, space: @space)
    [@other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path("/tactivities/#{@tactivity.id}/unschedule")
      assert last_response.redirect?
    end
    assert_equal ['Yoga', @tslot.id], [@tactivity.reload.name, @tactivity.tslot_id]
  end

  test "a member who's no longer interested in an activity takes only their own interest away" do
    create_gathering(privacy: 'open')
    create_timetable
    member = create_member
    other = create_member(name: 'Other Person')
    @tactivity.attendances.create!(account: other)

    # Not interested themselves, they take no one's away
    sign_in_with_rack(member)
    post gathering_path("/tactivities/#{@tactivity.id}/unattend")
    assert @tactivity.attendances.find_by(account: other)

    @tactivity.attendances.create!(account: member)
    post gathering_path("/tactivities/#{@tactivity.id}/unattend")
    assert_nil @tactivity.attendances.find_by(account: member)
    assert @tactivity.attendances.find_by(account: other)

    clear_cookies
    post gathering_path("/tactivities/#{@tactivity.id}/unattend")
    assert last_response.redirect?
    assert @tactivity.attendances.find_by(account: other)
  end
end
