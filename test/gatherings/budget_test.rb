require_relative '../test_config'

# A gathering's budget, inventory and options: who may list and change expenses and items, mark them reimbursed or
# provided, and move members between options. Listing and editing them in the browser are also in features_test.rb
class GatheringBudgetTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def create_other_gathering
    @other_account = FactoryBot.create(:account)
    @other_gathering = FactoryBot.create(:gathering, account: @other_account)
  end

  def create_spend(account: @account)
    @spend = @gathering.spends.create!(item: 'Vegetables', amount: 30, team: @gathering.teams.first, account: account)
  end

  def create_inventory_item
    @inventory_item = @gathering.inventory_items.create!(name: 'Tent', team: @gathering.teams.first, account: @account)
  end

  test 'a member lists an expense, which is theirs, and an admin unmarks it reimbursed' do
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(member)
    visit gathering_path('/budget')
    click_link 'List expense'
    within('#add-spend') do
      fill_in 'Item', with: 'Firewood'
      fill_in 'Cost', with: '45'
      assert page.has_no_field? 'Paid by'
      click_button 'Create spend'
    end
    assert page.has_link? 'Firewood'
    spend = @gathering.spends.find_by(item: 'Firewood')
    assert_equal [member.id, 45], [spend.account_id, spend.amount]

    spend.set(reimbursed: true)
    sign_in(@account)
    visit gathering_path('/budget')
    uncheck "spend-#{spend.id}-reimbursed"
    assert page.has_unchecked_field? "spend-#{spend.id}-reimbursed"
    refute spend.reload.reimbursed
  end

  test "a member's expenses are their own: they can't list one, or move one, as someone else's" do
    create_gathering(privacy: 'open')
    member = create_member
    other = create_member(name: 'Other Person')
    create_spend(account: other)

    sign_in_with_rack(member)
    post gathering_path('/spends/new'), spend: { item: 'Firewood', amount: 45, team_id: @gathering.teams.first.id, account_id: other.id }
    assert_equal member.id, @gathering.spends.find_by(item: 'Firewood').account_id
    post gathering_path("/spends/#{@spend.id}/edit"), spend: { item: 'Vegetables', amount: 30, account_id: member.id }
    assert_equal other.id, @spend.reload.account_id
  end

  test "nobody outside the gathering lists, edits or marks reimbursed its expenses" do
    create_gathering(privacy: 'open')
    create_spend
    create_other_gathering

    [@other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path('/spends/new'), spend: { item: 'Firewood', amount: 45, team_id: @gathering.teams.first.id }
      assert last_response.redirect?
      get gathering_path("/spends/#{@spend.id}/edit")
      assert last_response.redirect?
      post gathering_path("/spends/#{@spend.id}/edit"), spend: { item: 'Hijacked' }
      assert last_response.redirect?
      post gathering_path("/spends/#{@spend.id}/reimbursed"), reimbursed: true
      assert last_response.redirect?
    end
    refute @gathering.spends.find_by(item: 'Firewood')
    assert_equal 'Vegetables', @spend.reload.item
    refute @spend.reimbursed
  end

  test "a gathering's expense routes don't find another gathering's" do
    create_gathering(privacy: 'open')
    create_other_gathering
    other_spend = @other_gathering.spends.create!(item: 'Secret wine', amount: 99, team: @other_gathering.teams.first, account: @other_account)

    sign_in_with_rack(@account)
    get gathering_path("/spends/#{other_spend.id}/edit")
    assert_equal 404, last_response.status
    refute_includes last_response.body, 'Secret wine'
    post gathering_path("/spends/#{other_spend.id}/edit"), spend: { item: 'Hijacked' }
    assert_equal 404, last_response.status
    post gathering_path("/spends/#{other_spend.id}/reimbursed"), reimbursed: true
    assert_equal 404, last_response.status
    assert_equal 'Secret wine', other_spend.reload.item
    refute other_spend.reimbursed
  end

  test "a member chooses who brings an item, then that no one does" do
    create_gathering(privacy: 'open')
    create_inventory_item
    member = create_member
    sign_in(member)
    visit gathering_path('/inventory')
    find("select[aria-label='Responsible']").select 'Member Person'
    assert page.has_css? "select[aria-label='Responsible'] option[selected]", text: 'Member Person'
    assert_equal member.id, @inventory_item.reload.responsible_id

    find("select[aria-label='Responsible']").select ''
    assert page.has_no_css? "select[aria-label='Responsible'] option[selected]", text: 'Member Person'
    assert_nil @inventory_item.reload.responsible_id
  end

  test "an item is brought by one of the gathering's members, or no one" do
    create_gathering(privacy: 'open')
    create_inventory_item
    member = create_member
    create_other_gathering

    sign_in_with_rack(member)
    post gathering_path("/inventory_items/#{@inventory_item.id}/provided"), responsible_id: @other_account.id
    assert_equal 404, last_response.status
    assert_nil @inventory_item.reload.responsible_id
    post gathering_path("/inventory_items/#{@inventory_item.id}/provided"), responsible_id: member.id
    assert_equal member.id, @inventory_item.reload.responsible_id
  end

  test "nobody outside the gathering lists, edits or says who brings its items" do
    create_gathering(privacy: 'open')
    create_inventory_item
    create_other_gathering

    [@other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      post gathering_path('/inventory_items/new'), inventory_item: { name: 'Stove', team_id: @gathering.teams.first.id }
      assert last_response.redirect?
      get gathering_path("/inventory_items/#{@inventory_item.id}/edit")
      assert last_response.redirect?
      post gathering_path("/inventory_items/#{@inventory_item.id}/edit"), inventory_item: { name: 'Hijacked' }
      assert last_response.redirect?
      post gathering_path("/inventory_items/#{@inventory_item.id}/provided"), responsible_id: @account.id
      assert last_response.redirect?
    end
    refute @gathering.inventory_items.find_by(name: 'Stove')
    assert_equal ['Tent', nil], [@inventory_item.reload.name, @inventory_item.responsible_id]
  end

  test "a gathering's item routes don't find another gathering's" do
    create_gathering(privacy: 'open')
    create_other_gathering
    other_item = @other_gathering.inventory_items.create!(name: 'Secret stove', team: @other_gathering.teams.first, account: @other_account)

    sign_in_with_rack(@account)
    get gathering_path("/inventory_items/#{other_item.id}/edit")
    assert_equal 404, last_response.status
    refute_includes last_response.body, 'Secret stove'
    post gathering_path("/inventory_items/#{other_item.id}/edit"), inventory_item: { name: 'Hijacked' }
    assert_equal 404, last_response.status
    post gathering_path("/inventory_items/#{other_item.id}/provided"), responsible_id: @account.id
    assert_equal 404, last_response.status
    assert_equal ['Secret stove', nil], [other_item.reload.name, other_item.responsible_id]
  end

  test 'the old accommodation and transport pages go to the options' do
    create_gathering(privacy: 'open')
    %w[accoms transports].each do |path|
      get gathering_path("/#{path}")
      assert last_response.redirect?
      assert_equal gathering_path('/options'), URI(last_response.location).path
    end
  end

  test "an admin moves a member to another option, which then asks for that option's cost" do
    create_gathering(privacy: 'open')
    member = create_member
    tent = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account)
    cabin = @gathering.options.create!(name: 'Cabin', type: 'Accommodation', cost: 100, account: @account)
    optionship = tent.optionships.create!(account: member, gathering: @gathering)
    membership = @gathering.memberships.find_by(account: member)
    assert_equal 0, membership.requested_contribution.to_i

    sign_in(@account)
    visit gathering_path('/options')
    find("a[aria-label='Member Person: edit']").click
    within('#modal') do
      select 'Cabin (Accommodation)', from: 'Option'
      click_button 'Save contribution'
    end
    assert page.has_current_path?(gathering_path('/options'), ignore_query: true)
    assert_equal cabin.id, optionship.reload.option_id
    assert_equal 100, membership.reload.requested_contribution
  end

  test "a member can't be moved into an option that's full, but stays in a full one when it's saved again" do
    create_gathering(privacy: 'open')
    member = create_member
    other = create_member(name: 'Other Person')
    tent = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account)
    cabin = @gathering.options.create!(name: 'Cabin', type: 'Accommodation', capacity: 1, account: @account)
    cabin.optionships.create!(account: other, gathering: @gathering)
    optionship = tent.optionships.create!(account: member, gathering: @gathering)
    full_optionship = cabin.optionships.find_by(account: other)

    sign_in_with_rack(@account)
    post gathering_path("/optionships/#{optionship.id}/edit"), optionship: { option_id: cabin.id }
    assert last_response.ok?
    assert_includes last_response.body, 'is full'
    assert_equal tent.id, optionship.reload.option_id

    post gathering_path("/optionships/#{full_optionship.id}/edit"), optionship: { option_id: cabin.id }
    assert last_response.redirect?
    assert_equal cabin.id, full_optionship.reload.option_id
  end

  test "only the gathering's admins edit its members' options, and paid options themselves" do
    create_gathering(privacy: 'open')
    member = create_member
    other = create_member(name: 'Other Person')
    create_other_gathering
    tent = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account)
    cabin = @gathering.options.create!(name: 'Cabin', type: 'Accommodation', cost: 100, account: @account)
    optionship = tent.optionships.create!(account: other, gathering: @gathering)
    own_optionship = tent.optionships.create!(account: member, gathering: @gathering)

    [member, @other_account, nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      [optionship, own_optionship].each do |o|
        get gathering_path("/optionships/#{o.id}/edit")
        assert last_response.redirect?
        post gathering_path("/optionships/#{o.id}/edit"), optionship: { option_id: cabin.id }
        assert last_response.redirect?
      end
      get gathering_path("/options/#{cabin.id}/edit")
      assert last_response.redirect?
      post gathering_path("/options/#{cabin.id}/edit"), option: { name: 'Free cabin', cost: 0 }
      assert last_response.redirect?
    end
    assert_equal [tent.id, tent.id], [optionship.reload.option_id, own_optionship.reload.option_id]
    assert_equal ['Cabin', 100], [cabin.reload.name, cabin.cost]

    # A member may edit a free option, but not give it a cost
    sign_in_with_rack(member)
    post gathering_path("/options/#{tent.id}/edit"), option: { name: 'Tent', capacity: 5, cost: 50 }
    assert_equal [5, 0], [tent.reload.capacity, tent.cost]
  end

  test "a gathering's option routes don't find another gathering's optionships" do
    create_gathering(privacy: 'open')
    create_other_gathering
    other_option = @other_gathering.options.create!(name: 'Secret yurt', type: 'Accommodation', account: @other_account)
    other_optionship = other_option.optionships.create!(account: @other_account, gathering: @other_gathering)
    tent = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account)

    sign_in_with_rack(@account)
    get gathering_path("/optionships/#{other_optionship.id}/edit")
    assert_equal 404, last_response.status
    refute_includes last_response.body, 'Secret yurt'
    post gathering_path("/optionships/#{other_optionship.id}/edit"), optionship: { option_id: tent.id }
    assert_equal 404, last_response.status
    assert_equal other_option.id, other_optionship.reload.option_id
  end
end
