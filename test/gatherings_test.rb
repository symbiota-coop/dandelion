require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class GatheringsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def create_two_gatherings
    create_gathering
    @other_account = FactoryBot.create(:account)
    @other_gathering = FactoryBot.create(:gathering, account: @other_account)
  end

  test 'creating a gathering' do
    account = FactoryBot.create(:account)
    gathering = FactoryBot.build_stubbed(:gathering)
    sign_in(account)
    click_link 'Gatherings'
    click_link 'All gatherings'
    within('#content') { click_link 'Create a gathering' }
    fill_in 'Name', with: gathering.name
    fill_in 'URL', with: gathering.slug
    click_link 'Next'
    click_link 'Next'
    click_link 'Next'
    click_link 'Next'
    click_button 'Create gathering'
    assert page.has_content? 'created the gathering'
  end

  test 'editing a gathering' do
    create_gathering
    sign_in(@account)
    visit "/g/#{@gathering.slug}/edit"
    fill_in 'Name', with: (name = FactoryBot.build_stubbed(:gathering).name)
    click_button 'Update gathering'
    assert page.has_content? 'The gathering was saved'
    assert page.has_content? name
  end

  test 'copying a gathering without another admin destination redirects safely' do
    create_gathering
    sign_in(@account)

    visit "/g/#{@gathering.slug}"
    assert page.has_no_link? 'Copy'

    visit "/g/#{@gathering.slug}/copy"
    assert page.has_content? 'You need to be an admin of another gathering to copy into it.'
    assert_equal "/g/#{@gathering.slug}", page.current_path
  end

  test 'team edit rejects gathering_id from params' do
    create_two_gatherings
    team = @gathering.teams.find_by(name: 'General')

    sign_in_with_rack(@account)
    post "/g/#{@gathering.slug}/teams/#{team.id}/edit", team: { name: team.name, gathering_id: @other_gathering.id }

    assert_equal @gathering.id, team.reload.gathering_id
  end

  test 'teamship create cannot attach a team from another gathering' do
    create_two_gatherings
    other_team = @other_gathering.teams.create!(name: 'Kitchen', account: @other_account)

    sign_in_with_rack(@account)
    post "/g/#{@gathering.slug}/teamships/new", teamship: { account_id: @account.id, team_id: other_team.id }

    refute other_team.teamships.find_by(account: @account)
  end

  test 'optionship create cannot attach an option from another gathering' do
    create_two_gatherings
    other_option = @other_gathering.options.create!(name: 'Cabin', type: 'Accommodation', account: @other_account)

    sign_in_with_rack(@account)
    post "/g/#{@gathering.slug}/optionships/new", optionship: { account_id: @account.id, option_id: other_option.id }

    refute other_option.optionships.find_by(account: @account)
  end

  test 'verdict create rejects mapplication_id from params' do
    create_two_gatherings
    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    other_mapplication = @other_gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')

    sign_in_with_rack(@account)
    post "/mapplications/#{mapplication.id}/verdicts/create", verdict: { type: 'proposer', mapplication_id: other_mapplication.id }

    assert mapplication.verdicts.find_by(account: @account)
    refute other_mapplication.verdicts.find_by(account: @account)
  end

  test 'shift create cannot use a role from another rota' do
    create_two_gatherings
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    rslot = Rslot.create!(name: 'Morning', rota: rota)
    other_rota = @other_gathering.rotas.create!(name: 'Bar', account: @other_account)
    other_role = Role.create!(name: 'Barista', rota: other_rota)

    sign_in_with_rack(@account)
    post "/g/#{@gathering.slug}/rotas/#{rota.id}/create_shift", shift: { account_id: @account.id, role_id: other_role.id, rslot_id: rslot.id }

    assert_equal 404, last_response.status
    refute Shift.find_by(role: other_role)
    refute Shift.find_by(rslot: rslot)
  end

  test 'self-service shift create scopes roles and slots to its rota' do
    create_two_gatherings
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    rslot = Rslot.create!(name: 'Morning', rota: rota)
    other_rota = @other_gathering.rotas.create!(name: 'Bar', account: @other_account)
    other_role = Role.create!(name: 'Barista', rota: other_rota)

    sign_in_with_rack(@account)
    post '/shifts/create', rota_id: rota.id, role_id: other_role.id, rslot_id: rslot.id

    assert_equal 404, last_response.status
    refute Shift.find_by(role: other_role)
    refute Shift.find_by(rslot: rslot)
  end

  test 'member cannot reassign their shift to another account' do
    create_gathering
    member = FactoryBot.create(:account)
    other_member = FactoryBot.create(:account)
    @gathering.memberships.create!(account: member)
    @gathering.memberships.create!(account: other_member)
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    role = Role.create!(name: 'Cook', rota: rota)
    rslot = Rslot.create!(name: 'Morning', rota: rota)
    shift = Shift.create!(account: member, role: role, rslot: rslot, rota: rota)

    sign_in_with_rack(member)
    post "/shifts/#{shift.id}/edit", shift: { account_id: other_member.id }

    assert_equal member.id, shift.reload.account_id
    assert_equal member.id, shift.membership.account_id
  end

  test 'inventory item cannot be assigned a team from another gathering' do
    create_two_gatherings
    other_team = @other_gathering.teams.create!(name: 'Kitchen', account: @other_account)
    item = @gathering.inventory_items.build(name: 'Tent', team: other_team, account: @account)
    refute item.valid?
    assert_includes item.errors[:team], 'must belong to the same gathering'
  end

  test 'spend cannot be assigned a team from another gathering' do
    create_two_gatherings
    other_team = @other_gathering.teams.create!(name: 'Kitchen', account: @other_account)
    spend = @gathering.spends.build(item: 'Food', amount: 10, team: other_team, account: @account)
    refute spend.valid?
    assert_includes spend.errors[:team], 'must belong to the same gathering'
  end

  test 'admin reassigning a spend updates its membership' do
    create_gathering
    member = FactoryBot.create(:account)
    member_membership = @gathering.memberships.create!(account: member)
    team = @gathering.teams.find_by(name: 'General')
    spend = @gathering.spends.create!(item: 'Food', amount: 10, team: team, account: @account)

    sign_in_with_rack(@account)
    post "/g/#{@gathering.slug}/spends/#{spend.id}/edit", spend: { item: 'Food', amount: 10, team_id: team.id, account_id: member.id }

    spend.reload
    assert_equal member.id, spend.account_id
    assert_equal member_membership.id, spend.membership_id
  end

  test 'comment cannot attach a post from another commentable' do
    create_two_gatherings
    team = @gathering.teams.find_by(name: 'General')
    other_team = @other_gathering.teams.create!(name: 'Kitchen', account: @other_account)
    other_post = other_team.posts.create!(subject: 'Private', account: @other_account)

    sign_in_with_rack(@account)
    post '/comment', comment: { commentable_type: 'Team', commentable_id: team.id, post_id: other_post.id, body: 'Hello' }

    assert_equal 404, last_response.status
    assert_equal 0, other_post.comments.count
  end
end
