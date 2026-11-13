require_relative '../test_config'
require_relative '../helpers/gatherings_helpers'

# A gathering's timetables and their activities: who may make and change them, schedule activities and say they're
# interested. Creating, editing and dragging activities in the browser are also in features_test.rb
class GatheringTimetablesTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include GatheringsHelpers

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
    covers_route 'GET /g/:slug/tactivities/:id'
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

  test "a member isn't offered a space and slot on an activity's edit form unless members may schedule" do
    covers_route 'GET /g/:slug/tactivities/:id/edit'
    create_gathering(privacy: 'open')
    create_timetable
    sign_in(create_member)
    visit gathering_path("/tactivities/#{@tactivity.id}/edit")
    assert page.has_field? 'Activity name'
    assert page.has_no_field? 'Slot'

    @timetable.set(scheduling_by_all: true)
    visit gathering_path("/tactivities/#{@tactivity.id}/edit")
    assert page.has_field? 'Slot'
  end

  test "only the gathering's admins make and edit its timetables" do
    covers_route 'GET /g/:slug/timetables/:id/edit'
    covers_route 'GET /g/:slug/timetables/new'
    covers_route 'POST /g/:slug/timetables/:id/edit'
    covers_route 'POST /g/:slug/timetables/new'
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

  test "an activity can't be scheduled into another timetable's slot, or a slot that's taken" do
    covers_route 'POST /g/:slug/tactivities/:id/schedule'
    create_gathering(privacy: 'open')
    create_timetable
    other_timetable = @gathering.timetables.create!(name: 'Talks', account: @account)
    other_tslot = other_timetable.tslots.create!(name: 'Sunday')
    other_space = other_timetable.spaces.create!(name: 'Hall')
    taken = @timetable.tactivities.create!(name: 'Dance', account: @account, tslot: @tslot, space: @space)

    sign_in_with_rack(@account)
    post gathering_path("/tactivities/#{@tactivity.id}/schedule"), tslot_id: other_tslot.id, space_id: other_space.id
    assert_equal 422, last_response.status
    post gathering_path("/tactivities/#{@tactivity.id}/schedule"), tslot_id: @tslot.id, space_id: @space.id
    assert_equal 422, last_response.status
    assert_nil @tactivity.reload.tslot_id
    assert_equal [@tslot.id, @space.id], [taken.reload.tslot_id, taken.space_id]
  end

  test 'members schedule and unschedule activities only when the timetable lets all members schedule' do
    covers_route 'POST /g/:slug/tactivities/:id/edit'
    covers_route 'POST /g/:slug/tactivities/:id/unschedule'
    create_gathering(privacy: 'open')
    create_timetable
    member = create_member

    sign_in_with_rack(member)
    post gathering_path("/tactivities/#{@tactivity.id}/schedule"), tslot_id: @tslot.id, space_id: @space.id
    assert_equal 403, last_response.status
    assert_nil @tactivity.reload.tslot_id
    # Nor through the activity's edit form
    post gathering_path("/tactivities/#{@tactivity.id}/edit"), tactivity: { name: 'Yoga', tslot_id: @tslot.id, space_id: @space.id }
    assert_nil @tactivity.reload.tslot_id
    # Nor by creating it scheduled
    post gathering_path("/tactivities/create?timetable_id=#{@timetable.id}"), tactivity: { name: 'Sneaky', tslot_id: @tslot.id, space_id: @space.id }
    created = @timetable.tactivities.find_by(name: 'Sneaky')
    assert_equal [nil, nil], [created.tslot_id, created.space_id]
    created.destroy

    @tactivity.update_attributes!(tslot: @tslot, space: @space)
    post gathering_path("/tactivities/#{@tactivity.id}/unschedule")
    assert_equal 403, last_response.status
    post gathering_path("/tactivities/#{@tactivity.id}/edit"), tactivity: { name: 'Yoga', tslot_id: '', space_id: '' }
    assert_equal @tslot.id, @tactivity.reload.tslot_id

    @timetable.set(scheduling_by_all: true)
    post gathering_path("/tactivities/#{@tactivity.id}/unschedule")
    assert_nil @tactivity.reload.tslot_id
    post gathering_path("/tactivities/#{@tactivity.id}/schedule"), tslot_id: @tslot.id, space_id: @space.id
    assert last_response.ok?
    assert_equal [@tslot.id, @space.id, member.id], [@tactivity.reload.tslot_id, @tactivity.space_id, @tactivity.scheduled_by_id]
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
    covers_route 'POST /g/:slug/tactivities/:id/unattend'
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
