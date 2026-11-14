require_relative 'test_config'
require_relative 'helpers/gatherings_helpers'

# What each kind of notification says, links to and shows as its icon, created the way the app creates it: names escaped,
# and an optional record (who processed an application, scheduled an activity, added a member, listed an item, created
# an organisation) gone without raising. And the newsfeeds that show them
class NotificationsTest < ActiveSupport::TestCase
  include Rack::Test::Methods
  include GatheringsHelpers

  # A name with markup in it. sanitize_fields strips tags from names on save, so it's set with set, as a write that skips
  # validation would
  AWKWARD = 'Ann <b>&</b> Co'.freeze

  def awkward!(record, field = :name)
    record.set(field => AWKWARD)
    record
  end

  def strong(text)
    "<strong>#{ERB::Util.html_escape(text)}</strong>"
  end

  # The notification of this type about record, fresh from the database, so it reads its records as they are now
  def notification_of(record, type)
    Notification.find_by(notifiable_type: record.class.name, notifiable_id: record.id, type: type)
  end

  def assert_notification(notification, sentence, link, icon)
    assert notification, 'no notification'
    assert_equal sentence, notification.sentence
    assert_predicate notification.sentence, :html_safe?
    assert_equal link, notification.link
    assert_equal icon, notification.icon
  end

  def gathering_url(path = '')
    "#{ENV['BASE_URI']}/g/#{@gathering.slug}#{path}"
  end

  def create_awkward_gathering
    create_gathering(privacy: 'closed')
    awkward!(@account)
  end

  # Memberships

  test 'a member accepted on an application, by someone or by nobody now on record' do
    create_awkward_gathering
    applicant = awkward!(FactoryBot.create(:account))
    mapplication = @gathering.mapplications.create!(account: applicant, status: 'pending')
    mapplication.set(processed_by_id: @account.id)
    assert mapplication.accept
    membership = membership_of(applicant)

    assert_notification notification_of(membership, 'joined_gathering'),
                        "#{strong(AWKWARD)} was accepted by #{strong(AWKWARD)}",
                        ['View members', gathering_url('/members')], 'bi-person-fill-add'

    mapplication.set(processed_by_id: BSON::ObjectId.new)
    assert_equal "#{strong(AWKWARD)} was accepted", notification_of(membership, 'joined_gathering').sentence
    mapplication.set(processed_by_id: nil)
    assert_equal "#{strong(AWKWARD)} was accepted", notification_of(membership, 'joined_gathering').sentence
  end

  test 'a member added by someone, by someone since gone, and one who joined' do
    create_awkward_gathering
    added = awkward!(FactoryBot.create(:account))
    membership = @gathering.memberships.create!(account: added, unsubscribed: true, added_by: @account)
    assert_notification notification_of(membership, 'joined_gathering'),
                        "#{strong(AWKWARD)} was added by #{ERB::Util.html_escape(AWKWARD)}",
                        ['View members', gathering_url('/members')], 'bi-person-fill-add'

    membership.set(added_by_id: BSON::ObjectId.new)
    assert_equal "#{strong(AWKWARD)} joined the gathering", notification_of(membership, 'joined_gathering').sentence

    joined = @gathering.memberships.create!(account: FactoryBot.create(:account, name: 'Joiner'))
    assert_equal "#{strong('Joiner')} joined the gathering", notification_of(joined, 'joined_gathering').sentence
  end

  test 'someone no longer a member, and an application deleted' do
    create_awkward_gathering
    leaver = awkward!(create_gathering_member)
    membership_of(leaver).destroy
    assert_notification notification_of(leaver, 'left_gathering'), "#{strong(AWKWARD)} is no longer a member",
                        ['View members', gathering_url('/members')], 'bi-box-arrow-right'

    applicant = awkward!(FactoryBot.create(:account))
    @gathering.mapplications.create!(account: applicant, status: 'pending').destroy
    assert_notification notification_of(applicant, 'mapplication_removed'), "#{strong(AWKWARD)}'s application was deleted",
                        ['View applications', gathering_url('/applications')], 'bi-file-text'
  end

  test 'an admin unadmins a member, which says who did' do
    create_awkward_gathering
    member = awkward!(create_gathering_member)
    membership = membership_of(member)
    membership.set(admin: true)
    sign_in_with_rack(@account)

    post gathering_path("/memberships/#{membership.id}/unadmin")
    assert_equal 302, last_response.status
    refute membership.reload.admin?
    assert_notification notification_of(membership, 'unadmined'), "#{strong(AWKWARD)} was unadmined by #{strong(AWKWARD)}",
                        ['View members', gathering_url('/members')], 'bi-key'
  end

  # Activities

  test 'scheduling and unscheduling an activity on a timetable all members schedule, saying who did while they are on record' do
    create_awkward_gathering
    create_timetable(scheduling_by_all: true)
    awkward!(@tactivity)
    sign_in_with_rack(@account)
    activity_link = ['View activity', gathering_url("/tactivities/#{@tactivity.id}")]

    post gathering_path("/tactivities/#{@tactivity.id}/schedule"), tslot_id: @tslot.id, space_id: @space.id
    assert_equal 200, last_response.status
    assert_notification notification_of(@tactivity, 'scheduled_tactivity'),
                        "#{strong(AWKWARD)} scheduled the activity #{strong(AWKWARD)}", activity_link, 'bi-calendar-plus'
    @tactivity.set(scheduled_by_id: BSON::ObjectId.new)
    assert_equal "The activity #{strong(AWKWARD)} was scheduled", notification_of(@tactivity, 'scheduled_tactivity').sentence

    post gathering_path("/tactivities/#{@tactivity.id}/unschedule")
    assert_equal 302, last_response.status
    assert_nil notification_of(@tactivity, 'scheduled_tactivity')
    assert_notification notification_of(@tactivity, 'unscheduled_tactivity'),
                        "#{strong(AWKWARD)} unscheduled the activity #{strong(AWKWARD)}", activity_link, 'bi-calendar-minus'
    @tactivity.set(scheduled_by_id: nil)
    assert_equal "The activity #{strong(AWKWARD)} was unscheduled", notification_of(@tactivity, 'unscheduled_tactivity').sentence
  end

  test 'scheduling an activity on a timetable only admins schedule notifies nobody' do
    create_gathering(privacy: 'closed')
    create_timetable
    sign_in_with_rack(@account)
    post gathering_path("/tactivities/#{@tactivity.id}/schedule"), tslot_id: @tslot.id, space_id: @space.id
    assert_equal 200, last_response.status
    assert_equal @tslot.id, @tactivity.reload.tslot_id
    assert_nil notification_of(@tactivity, 'scheduled_tactivity')
  end

  # Nothing in the app creates this kind now (an attendance has no notifications), but older ones still render
  test 'someone interested in an activity' do
    create_awkward_gathering
    create_timetable
    awkward!(@tactivity)
    attendance = @tactivity.attendances.create!(account: @account)
    notification = Notification.create!(circle: @gathering, notifiable: attendance, type: 'interested_in_tactivity')
    assert_notification Notification.find(notification.id), "#{strong(AWKWARD)} is interested in #{strong(AWKWARD)}",
                        ['View activity', gathering_url("/tactivities/#{@tactivity.id}")], 'bi-hand-thumbs-up'
  end

  # Comments

  test 'a comment on an application' do
    create_awkward_gathering
    applicant = awkward!(FactoryBot.create(:account))
    mapplication = @gathering.mapplications.create!(account: applicant, status: 'pending')
    post = mapplication.posts.create!(account: @account, subject: 'Thoughts')
    comment = post.comments.create!(account: @account, body: 'Welcome')
    assert_notification notification_of(comment, 'commented'), "#{strong(AWKWARD)} commented on #{strong(AWKWARD)}'s application",
                        ['View post', "#{ENV['BASE_URI']}/g/#{@gathering.slug}/mapplications/#{mapplication.id}#post-#{post.id}"],
                        'bi-chat-left-text'
  end

  test 'a thread started in a team and a reply to it' do
    create_awkward_gathering
    team = awkward!(@gathering.teams.find_by(name: 'General'))
    replier = FactoryBot.create(:account, name: 'Replier')
    @gathering.memberships.create!(account: replier)
    post = awkward!(team.posts.create!(account: @account, subject: 'Rota'), :subject)
    first = post.comments.create!(account: @account, body: 'Who cooks?')
    reply = post.comments.create!(account: replier, body: 'Me')
    thread = strong("#{AWKWARD}/#{AWKWARD}")
    post_link = ['View post', "#{ENV['BASE_URI']}/g/#{@gathering.slug}/teams/#{team.id}#post-#{post.id}"]

    assert_notification notification_of(first, 'commented'), "#{strong(AWKWARD)} started a thread #{thread}", post_link, 'bi-chat-left-text'
    assert_notification notification_of(reply, 'commented'), "#{strong('Replier')} replied to #{thread}", post_link, 'bi-chat-left-text'
  end

  test "a 💚 reaction shows as a heart, and any other reaction is escaped" do
    create_awkward_gathering
    team = @gathering.teams.find_by(name: 'General')
    reactor = awkward!(create_gathering_member)
    post = team.posts.create!(account: @account, subject: 'Rota')
    comment = post.comments.create!(account: @account, body: 'Who cooks?')
    in_thread = "#{strong("#{AWKWARD}'s")} comment in #{strong("#{team.name}/Rota")}"
    post_link = ['View post', "#{ENV['BASE_URI']}/g/#{@gathering.slug}/teams/#{team.id}#post-#{post.id}"]

    heart = comment.comment_reactions.create!(account: reactor, body: '💚')
    assert_notification notification_of(heart, 'reacted_to_a_comment'),
                        %(#{strong(AWKWARD)} reacted with <i class="text-primary bi bi-heart-fill"></i> to #{in_thread}), post_link, 'bi-hand-thumbs-up'

    other = comment.comment_reactions.create!(account: FactoryBot.create(:account, name: 'Other'), body: '👍')
    assert_equal "#{strong('Other')} reacted with 👍 to #{in_thread}", notification_of(other, 'reacted_to_a_comment').sentence
    other.set(body: '<img src=x onerror=alert(1)>')
    assert_equal "#{strong('Other')} reacted with &lt;img src=x onerror=alert(1)&gt; to #{in_thread}",
                 notification_of(other, 'reacted_to_a_comment').sentence
  end

  # Money and things

  test 'a payment, in its currency, and none while the gathering hides what members paid' do
    create_awkward_gathering
    member = awkward!(create_gathering_member)
    payment = Payment.create!(membership: membership_of(member), amount: 50, currency: 'EUR')
    payment.payment_completed!
    assert_notification notification_of(payment, 'created_payment'), "#{strong(AWKWARD)} made a payment of €50",
                        ['View budget', gathering_url('/budget')], 'bi-cash-coin'

    @gathering.set(hide_paid: true)
    hidden = Payment.create!(membership: membership_of(member), amount: 20, currency: 'EUR')
    hidden.payment_completed!
    assert_nil notification_of(hidden, 'created_payment')
  end

  test 'an item listed by someone, and by someone no longer on record' do
    create_awkward_gathering
    item = awkward!(@gathering.inventory_items.create!(name: 'Tent', team: @gathering.teams.first, account: @account))
    assert_notification notification_of(item, 'created_inventory_item'), "#{strong(AWKWARD)} listed the item #{strong(AWKWARD)}",
                        ['View inventory', gathering_url('/inventory')], 'bi-wrench'

    item.set(account_id: nil)
    assert_equal "Someone listed the item #{strong(AWKWARD)}", notification_of(item, 'created_inventory_item').sentence
  end

  # An account's own

  test 'a new organisation, by its creator or by nobody now on record' do
    creator = awkward!(FactoryBot.create(:account))
    organisation = awkward!(FactoryBot.create(:organisation, account: creator))
    assert_notification notification_of(organisation, 'created_organisation'),
                        "#{strong(AWKWARD)} created the organisation #{strong(AWKWARD)}",
                        ['View organisation', "#{ENV['BASE_URI']}/o/#{organisation.slug}"], 'bi-flag-fill'

    organisation.set(account_id: nil)
    assert_equal "A new organisation #{strong(AWKWARD)} was created", notification_of(organisation, 'created_organisation').sentence
  end

  test "an order says who is going, but not for someone who hasn't signed in" do
    create_event
    awkward!(@event)
    buyer = awkward!(FactoryBot.create(:account, has_signed_in: true))
    order = @event.orders.create!(account: buyer, currency: @event.currency, value: 0, payment_completed: true)
    order.create_order_notification
    assert_notification notification_of(order, 'created_order'), "#{strong(AWKWARD)} is going to #{strong(AWKWARD)}",
                        ['View event', "#{ENV['BASE_URI']}/e/#{@event.slug}"], 'bi-ticket-detailed-fill'

    unseen = @event.orders.create!(account: FactoryBot.create(:account), currency: @event.currency, value: 0, payment_completed: true)
    unseen.create_order_notification
    assert_nil notification_of(unseen, 'created_order')
  end

  test 'feedback on an event, and on one since gone' do
    create_event
    awkward!(@event)
    reviewer = awkward!(FactoryBot.create(:account))
    event_feedback = @event.event_feedbacks.create!(account: reviewer, rating: 4)
    assert_notification notification_of(event_feedback, 'left_feedback'), "#{strong(AWKWARD)} left feedback on #{strong(AWKWARD)}",
                        ['View event', "#{ENV['BASE_URI']}/e/#{@event.slug}"], 'bi-chat-left-quote'

    event_feedback.set(event_id: nil)
    assert_equal "#{strong(AWKWARD)} left feedback on an event", notification_of(event_feedback, 'left_feedback').sentence
  end

  # Newsfeeds

  test "a gathering's newsfeed shows each kind, names escaped" do
    covers_route 'GET /g/:slug'
    create_awkward_gathering
    member = awkward!(create_gathering_member)
    applicant = FactoryBot.create(:account, name: 'Applicant')
    @gathering.mapplications.create!(account: applicant, status: 'pending').destroy
    Payment.create!(membership: membership_of(member), amount: 30, currency: 'USD').payment_completed!
    @gathering.inventory_items.create!(name: 'Tent & poles', team: @gathering.teams.first, account: member)
    team = @gathering.teams.find_by(name: 'General')
    comment = team.posts.create!(account: member, subject: 'Rota').comments.create!(account: member, body: 'Who cooks?')
    comment.comment_reactions.create!(account: @account, body: '💚')
    leaver = FactoryBot.create(:account, name: 'Leaver')
    @gathering.memberships.create!(account: leaver).destroy

    sign_in_with_rack(@account)
    get gathering_path, {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
    assert_equal 200, last_response.status
    [
      "#{strong(AWKWARD)} joined the gathering",
      "#{strong('Applicant')}'s application was deleted",
      "#{strong(AWKWARD)} made a payment of $30",
      "#{strong(AWKWARD)} listed the item #{strong('Tent & poles')}",
      "#{strong(AWKWARD)} started a thread #{strong("#{team.name}/Rota")}",
      %(#{strong(AWKWARD)} reacted with <i class="text-primary bi bi-heart-fill"></i> to #{strong("#{AWKWARD}'s")} comment),
      "#{strong('Leaver')} is no longer a member"
    ].each { |sentence| assert_includes last_response.body, sentence }
    refute_includes last_response.body, '<b>&</b>'
  end

  test "someone's home newsfeed shows their organisations, orders and feedback, names escaped" do
    covers_route 'GET /'
    create_event(name: 'Gig')
    awkward!(@account).set(has_signed_in: true)
    @event.orders.create!(account: @account, currency: @event.currency, value: 0, payment_completed: true).create_order_notification
    @event.event_feedbacks.create!(account: @account, rating: 5)

    sign_in_with_rack(@account)
    get '/', {}, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest'
    assert_equal 200, last_response.status
    [
      "#{strong(AWKWARD)} created the organisation #{strong(@organisation.name)}",
      "#{strong(AWKWARD)} is going to #{strong('Gig')}",
      "#{strong(AWKWARD)} left feedback on #{strong('Gig')}"
    ].each { |sentence| assert_includes last_response.body, sentence }
    refute_includes last_response.body, '<b>&</b>'
  end
end
