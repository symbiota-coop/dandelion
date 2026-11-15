require_relative '../test_config'
require_relative '../helpers/gatherings_helpers'

# Who may make and change a gathering's rotas and their slots. Creating and editing them in the browser are also in
# features_test.rb, and shifts in gatherings_test.rb
class GatheringRotasTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include GatheringsHelpers

  test 'an admin sets how many shift points a slot is worth, and its shifts count them' do
    covers_route 'POST /g/:slug/rslots/:id/edit'
    create_gathering(privacy: 'open')
    create_rota
    member = create_gathering_member
    Shift.create!(account: member, role: @role, rslot: @rslot, rota: @rota)
    sign_in(@account)
    visit gathering_path("/rotas/#{@rota.id}")
    click_link 'Morning'
    within('#modal') do
      fill_in 'Worth', with: '2.5'
      click_button 'Update slot'
    end
    assert page.has_link? 'Edit rota'
    assert_equal 2.5, @rslot.reload.worth
    assert_equal 2.5, @rota.shifts.find_by(account: member).worth
  end

  test "only the gathering's admins make and edit its rotas and their slots" do
    covers_route 'GET /g/:slug/rotas/new'
    covers_route 'POST /g/:slug/rotas/new'
    create_gathering(privacy: 'open')
    create_rota
    member = create_gathering_member
    other_admin = FactoryBot.create(:account)
    FactoryBot.create(:gathering, account: other_admin)

    [member, other_admin, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get gathering_path('/rotas/new')
      assert last_response.redirect?
      post gathering_path('/rotas/new'), rota: { name: 'Bar' }
      assert last_response.redirect?
      get gathering_path("/rotas/#{@rota.id}/edit")
      assert last_response.redirect?
      post gathering_path("/rotas/#{@rota.id}/edit"), rota: { name: 'Hijacked' }
      assert last_response.redirect?
      get gathering_path("/rslots/#{@rslot.id}/edit")
      assert last_response.redirect?
      post gathering_path("/rslots/#{@rslot.id}/edit"), rslot: { name: 'Hijacked', worth: 10 }
      assert last_response.redirect?
    end
    refute @gathering.rotas.find_by(name: 'Bar')
    assert_equal 'Kitchen', @rota.reload.name
    assert_equal ['Morning', 1.0], [@rslot.reload.name, @rslot.worth]

    sign_in_with_rack(@account)
    post gathering_path('/rotas/new'), rota: { name: 'Bar' }
    assert @gathering.rotas.find_by(name: 'Bar')
    post gathering_path("/rotas/#{@rota.id}/edit"), rota: { name: 'Kitchen shifts' }
    assert_equal 'Kitchen shifts', @rota.reload.name
  end

  test "a gathering's rota and slot edit routes don't find another gathering's" do
    covers_route 'GET /g/:slug/rotas/:id/edit'
    covers_route 'POST /g/:slug/rotas/:id/edit'
    create_gathering(privacy: 'open')
    other_account = FactoryBot.create(:account)
    other_gathering = FactoryBot.create(:gathering, account: other_account)
    other_rota = other_gathering.rotas.create!(name: 'Secret bar', account: other_account)
    other_rslot = Rslot.create!(name: 'Secret evening', rota: other_rota)

    sign_in_with_rack(@account)
    get gathering_path("/rotas/#{other_rota.id}/edit")
    assert_equal 404, last_response.status
    refute_includes last_response.body, 'Secret bar'
    post gathering_path("/rotas/#{other_rota.id}/edit"), rota: { name: 'Hijacked' }
    assert_equal 404, last_response.status
    get gathering_path("/rslots/#{other_rslot.id}/edit")
    assert_equal 404, last_response.status
    refute_includes last_response.body, 'Secret evening'
    post gathering_path("/rslots/#{other_rslot.id}/edit"), rslot: { name: 'Hijacked' }
    assert_equal 404, last_response.status
    assert_equal ['Secret bar', 'Secret evening'], [other_rota.reload.name, other_rslot.reload.name]
  end

  test "an open gathering's rota CSV gives a member only the phone numbers their owners' privacy shows them" do
    covers_route 'GET /g/:slug/rotas/:id'
    create_gathering(privacy: 'open')
    create_rota
    hidden = create_gathering_member(name: 'Hidden Person', phone: '+447700900123', phone_privacy: 'Only me')
    Shift.create!(account: hidden, role: @role, rslot: @rslot, rota: @rota)
    viewer = create_gathering_member(name: 'Viewer Person')

    sign_in_with_rack(viewer)
    get gathering_path("/rotas/#{@rota.id}.csv")
    assert_equal ['Morning', 'Hidden Person'], CSV.parse(last_response.body).last

    sign_in_with_rack(@account)
    get gathering_path("/rotas/#{@rota.id}.csv")
    assert_equal ['Morning', 'Hidden Person +447700900123'], CSV.parse(last_response.body).last
  end

  # A gathering that demands payment confirms a member once they've paid. A shift they took before then is still theirs,
  # but not theirs to change until they've paid
  def create_unpaid_member_with_shift
    create_gathering(privacy: 'open', demand_payment: true)
    create_rota
    @member = create_gathering_member
    @shift = Shift.create!(account: @member, role: @role, rslot: @rslot, rota: @rota)
    @other_rslot = Rslot.create!(name: 'Evening', rota: @rota)
    refute membership_of(@member).confirmed?
  end

  test "a member who hasn't paid isn't shown the rota or their shift's edit link, until they pay" do
    create_unpaid_member_with_shift
    sign_in(@member)
    visit gathering_path("/rotas/#{@rota.id}")
    assert page.has_content?('You must make a payment before accessing that page.')
    assert page.has_current_path?(gathering_path, ignore_query: true)
    assert page.has_no_css?("a[href='#{gathering_path("/shifts/#{@shift.id}/edit")}']", visible: :all)

    membership_of(@member).set(paid: 10)
    visit gathering_path("/rotas/#{@rota.id}")
    assert page.has_css?("a[href='#{gathering_path("/shifts/#{@shift.id}/edit")}']", visible: :all)
  end

  test "a member who hasn't paid can't open, change or drop their own shift, and can once they've paid" do
    covers_route 'GET /g/:slug/shifts/:id/edit'
    covers_route 'POST /g/:slug/shifts/:id/edit'
    covers_route 'POST /g/:slug/shifts/:id/destroy'
    create_unpaid_member_with_shift
    sign_in_with_rack(@member)

    get gathering_path("/shifts/#{@shift.id}/edit")
    assert_equal gathering_path, URI(last_response.location).path
    post gathering_path("/shifts/#{@shift.id}/edit"), shift: { rslot_id: @other_rslot.id }
    assert_equal gathering_path, URI(last_response.location).path
    post gathering_path("/shifts/#{@shift.id}/destroy")
    assert_equal gathering_path, URI(last_response.location).path
    follow_redirect!
    assert_includes last_response.body, 'You must make a payment before accessing that page.'
    assert_equal @rslot.id, Shift.find(@shift.id).rslot_id

    membership_of(@member).set(paid: 10)
    get gathering_path("/shifts/#{@shift.id}/edit")
    assert last_response.ok?
    assert_includes last_response.body, 'Update shift'
    post gathering_path("/shifts/#{@shift.id}/edit"), shift: { rslot_id: @other_rslot.id }
    assert_equal gathering_path("/rotas/#{@rota.id}"), URI(last_response.location).path
    assert_equal @other_rslot.id, @shift.reload.rslot_id
    post gathering_path("/shifts/#{@shift.id}/destroy")
    assert_nil Shift.find(@shift.id)
  end
end
