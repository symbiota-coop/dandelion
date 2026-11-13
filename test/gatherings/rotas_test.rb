require_relative '../test_config'

# Who may make and change a gathering's rotas and their slots. Creating and editing them in the browser are also in
# features_test.rb, and shifts in gatherings_test.rb
class GatheringRotasTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def create_rota
    @rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    @role = Role.create!(name: 'Cook', rota: @rota)
    @rslot = Rslot.create!(name: 'Morning', rota: @rota)
  end

  test 'an admin sets how many shift points a slot is worth, and its shifts count them' do
    covers_route 'POST /g/:slug/rslots/:id/edit'
    create_gathering(privacy: 'open')
    create_rota
    member = create_member
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
    member = create_member
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
end
