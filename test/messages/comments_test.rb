require_relative '../test_config'

# Comments in discussions (a gathering's teams, timetable activities and applications, events and activity
# applications), with their reactions, read receipts, polls, files and emails: who may read and take part in each
class MessagesCommentsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  # A thread in @gathering's General team, opened by @member with @comment
  def team_thread
    create_gathering
    @team = @gathering.teams.find_by(name: 'General')
    @member = create_member
    @post = @team.posts.create!(account: @member, subject: 'Rota')
    @comment = @post.comments.create!(account: @member, body: 'Secret plans')
  end

  # A request as the page's pagelets make it, which a refusal answers with 403 rather than a redirect
  def xhr(method, path, params = {})
    send(method, path, params, 'HTTP_X_REQUESTED_WITH' => 'XMLHttpRequest')
  end

  def assert_refused(text = nil)
    assert_equal 403, last_response.status
    refute_includes last_response.body, text if text
  end

  # A text file to attach, named name
  def upload(name)
    file = Tempfile.new(['upload', File.extname(name)])
    file.write('Hello')
    file.close
    Rack::Test::UploadedFile.new(file.path, 'text/plain', original_filename: name)
  end

  # Each kind of discussion, with someone who may read it and someone who may not

  test "a gathering's team, timetable activity and application discussions are its confirmed members'" do
    team_thread
    timetable = @gathering.timetables.create!(name: 'Main', account: @account)
    tactivity = @gathering.tactivities.create!(name: 'Yoga', account: @member, timetable: timetable,
                                               membership: @gathering.memberships.find_by(account: @member))
    mapplication = @gathering.mapplications.create!(account: FactoryBot.create(:account), status: 'pending')
    # An admin of another gathering
    outsider = FactoryBot.create(:account)
    FactoryBot.create(:gathering, account: outsider)

    [@team, tactivity, mapplication].each do |commentable|
      commentable.posts.create!(account: @member, subject: 'Thread').comments.create!(account: @member, body: "About #{commentable.class}")

      sign_in_with_rack(@member)
      xhr :get, '/commentable', commentable_type: commentable.class.name, commentable_id: commentable.id
      assert last_response.ok?
      assert_includes last_response.body, "About #{commentable.class}"

      sign_in_with_rack(outsider)
      xhr :get, '/commentable', commentable_type: commentable.class.name, commentable_id: commentable.id
      assert_refused "About #{commentable.class}"
    end
  end

  test 'members who have not paid where a gathering demands it cannot read its discussions' do
    team_thread
    @gathering.set(demand_payment: true)

    sign_in_with_rack(@member)
    xhr :get, '/commentable', commentable_type: 'Team', commentable_id: @team.id
    assert_refused 'Secret plans'

    @gathering.memberships.find_by(account: @member).set(paid: 10)
    xhr :get, '/commentable', commentable_type: 'Team', commentable_id: @team.id
    assert last_response.ok?
    assert_includes last_response.body, 'Secret plans'
  end

  test "an event's chat is its attendees' and admins', unless its discussion is hidden" do
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
    @event.discussion_post!(attendee).comments.create!(account: attendee, commentable: @event, body: 'See you there')

    [attendee, @account].each do |viewer|
      sign_in_with_rack(viewer)
      xhr :get, '/chat', commentable_type: 'Event', commentable_id: @event.id
      assert last_response.ok?
      assert_includes last_response.body, 'See you there'
    end

    sign_in_with_rack(FactoryBot.create(:account))
    xhr :get, '/chat', commentable_type: 'Event', commentable_id: @event.id
    assert_refused 'See you there'

    @event.set(hide_discussion: true)
    sign_in_with_rack(attendee)
    xhr :get, '/chat', commentable_type: 'Event', commentable_id: @event.id
    assert_refused 'See you there'
  end

  test "an activity application's discussion is the activity's admins', not the applicant's" do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    applicant = FactoryBot.create(:account)
    application = activity.activity_applications.create!(account: applicant, status: 'Pending')
    application.posts.create!(account: @account, subject: 'Thoughts').comments.create!(account: @account, body: 'Strong candidate')

    sign_in_with_rack(@account)
    xhr :get, '/commentable', commentable_type: 'ActivityApplication', commentable_id: application.id
    assert last_response.ok?
    assert_includes last_response.body, 'Strong candidate'

    sign_in_with_rack(applicant)
    xhr :get, '/commentable', commentable_type: 'ActivityApplication', commentable_id: application.id
    assert_refused 'Strong candidate'
  end

  test 'only the kinds of record that have discussions can be asked for' do
    team_thread
    sign_in_with_rack(@member)
    xhr :get, '/commentable', commentable_type: 'Account', commentable_id: @member.id
    assert_refused
    xhr :get, '/chat', commentable_type: 'Gathering', commentable_id: @gathering.id
    assert_refused
  end

  test 'signed out, a discussion sends you to sign in' do
    team_thread
    get '/commentable', commentable_type: 'Team', commentable_id: @team.id
    assert last_response.redirect?
    assert_includes last_response.location, '/accounts/sign_in'
    refute_includes last_response.body, 'Secret plans'
  end

  # Outsiders, with the ids of a discussion they're not part of

  test "outsiders can't read a private discussion's posts, replies, reactions, read receipts or polls by their ids" do
    team_thread
    @comment.comment_reactions.create!(account: @member, body: '🎉')
    @comment.read_receipts.create!(account: @member)
    @comment.voptions.create!(account: @member, text: 'Tuesday')
    outsider = FactoryBot.create(:account)
    sign_in_with_rack(outsider)

    ["/posts/#{@post.id}", "/posts/#{@post.id}/post_replies", "/comments/#{@comment.id}/reactions",
     "/comments/#{@comment.id}/read_receipts", "/comments/#{@comment.id}/voptions"].each do |path|
      xhr :get, path
      assert_refused 'Secret plans'
      refute_includes last_response.body, @member.name, path
      refute_includes last_response.body, 'Tuesday', path
    end
    refute @comment.read_receipts.and(account: outsider).exists?
  end

  test "outsiders can't react, unreact, vote, add poll options or attach files in a private discussion" do
    team_thread
    @comment.comment_reactions.create!(account: @member, body: '🎉')
    voption = @comment.voptions.create!(account: @member, text: 'Tuesday')
    outsider = FactoryBot.create(:account)
    # An outsider's own reaction, from before they left, stays: refusing them means not even that is touched
    @comment.comment_reactions.create!(account: outsider, body: '👀')
    @post.comments.create!(account: outsider, body: 'From before I left')
    own_comment = @post.comments.find_by(account: outsider)
    sign_in_with_rack(outsider)

    xhr :post, "/comments/#{@comment.id}/react", body: '👍'
    assert_refused
    xhr :get, "/comments/#{@comment.id}/unreact"
    assert_refused
    xhr :post, "/voptions/#{voption.id}/vote", vote: true
    assert_refused
    xhr :post, '/voptions/create', comment_id: @comment.id, text: 'Never'
    assert_refused
    xhr :post, "/comments/#{own_comment.id}/file", file: upload('notes.txt')
    assert_refused

    assert_equal %w[🎉 👀], @comment.comment_reactions.order('created_at asc').pluck(:body)
    assert_equal 0, voption.votes.count
    assert_equal ['Tuesday'], @comment.voptions.pluck(:text)
    assert_nil own_comment.reload.file_uid
  end

  # Reactions

  test 'members react to a comment once each, with one word, and unreact only their own reaction' do
    team_thread
    other_member = create_member(name: 'Other Member')
    sign_in_with_rack(other_member)

    xhr :post, "/comments/#{@comment.id}/react", body: '🙌 hooray'
    assert last_response.ok?
    xhr :post, "/comments/#{@comment.id}/react", body: '👀'
    assert_equal ['🙌'], @comment.comment_reactions.pluck(:body)
    reaction = @comment.comment_reactions.first
    assert_equal other_member.id, reaction.account_id
    assert_equal @post.id, reaction.post_id

    xhr :get, "/comments/#{@comment.id}/reactions"
    assert last_response.ok?
    assert_includes last_response.body, '🙌'
    assert_includes last_response.body, 'Other Member'

    # Someone with no reaction of their own unreacting leaves others' alone
    sign_in_with_rack(@member)
    xhr :get, "/comments/#{@comment.id}/unreact"
    assert last_response.ok?
    assert_equal ['🙌'], @comment.comment_reactions.pluck(:body)

    sign_in_with_rack(other_member)
    xhr :get, "/comments/#{@comment.id}/unreact"
    assert_equal 0, @comment.comment_reactions.count
  end

  test "an event's attendees can react to its chat" do
    create_event(prices: [0])
    attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
    comment = @event.discussion_post!(@account).comments.create!(account: @account, commentable: @event, body: 'Welcome')

    sign_in_with_rack(attendee)
    xhr :post, "/comments/#{comment.id}/react", body: '💚'
    assert last_response.ok?
    assert_equal [attendee.id], comment.comment_reactions.pluck(:account_id)

    sign_in_with_rack(FactoryBot.create(:account))
    xhr :post, "/comments/#{comment.id}/react", body: '👎'
    assert_refused
    assert_equal 1, comment.comment_reactions.count
  end

  # Read receipts

  test "reading a gathering thread marks its comments read, which its members can see who's read" do
    team_thread
    reader = create_member(name: 'Careful Reader')
    sign_in_with_rack(reader)

    xhr :get, "/posts/#{@post.id}"
    assert last_response.ok?
    assert_includes last_response.body, 'Secret plans'
    assert @comment.read_receipts.and(account: reader).exists?

    xhr :get, "/posts/#{@post.id}"
    assert_equal 1, @comment.read_receipts.and(account: reader).count

    sign_in_with_rack(@member)
    xhr :get, "/comments/#{@comment.id}/read_receipts"
    assert last_response.ok?
    assert_includes last_response.body, 'Careful Reader'
  end

  # Replies

  test "a thread's replies are shown to its discussion's members" do
    team_thread
    @post.comments.create!(account: @account, body: 'Count me in')

    sign_in_with_rack(@member)
    xhr :get, "/posts/#{@post.id}/post_replies"
    assert last_response.ok?
    assert_includes last_response.body, 'Count me in'
  end

  # Polls

  test 'members vote once per option of a poll, and can take their vote back' do
    team_thread
    tuesday = @comment.voptions.create!(account: @member, text: 'Tuesday')
    wednesday = @comment.voptions.create!(account: @member, text: 'Wednesday')
    voter = create_member(name: 'Keen Voter')
    sign_in_with_rack(voter)

    xhr :post, "/voptions/#{tuesday.id}/vote", vote: true
    assert last_response.ok?
    assert_equal [voter.id], tuesday.votes.pluck(:account_id)

    # The options are checkboxes, so one person can choose more than one
    xhr :post, "/voptions/#{wednesday.id}/vote", vote: true
    assert_equal 1, wednesday.votes.count

    xhr :get, "/comments/#{@comment.id}/voptions"
    assert last_response.ok?
    assert_includes last_response.body, 'Tuesday'
    assert_includes last_response.body, 'Keen Voter'

    # Unticking sends no vote
    xhr :post, "/voptions/#{tuesday.id}/vote"
    assert last_response.ok?
    assert_equal 0, tuesday.votes.count
    assert_equal 1, wednesday.votes.count
  end

  test "a member ticks a poll's option on the team's page, and unticks it" do
    team_thread
    @comment.voptions.create!(account: @member, text: 'Tuesday')
    voter = create_member(name: 'Keen Voter')
    sign_in(voter)
    visit gathering_path("/teams/#{@team.id}")
    assert page.has_content?('Secret plans')

    poll = "[data-pagelet-url='/comments/#{@comment.id}/voptions']"

    check 'Tuesday'
    assert page.has_css?("#{poll} .image-wall")
    assert_equal [voter.id], @comment.voptions.first.votes.pluck(:account_id)

    uncheck 'Tuesday'
    assert page.has_no_css?("#{poll} .image-wall")
    assert page.has_unchecked_field?('Tuesday')
    assert_equal 0, @comment.voptions.first.votes.count
  end

  test "taking back a vote leaves other people's" do
    team_thread
    tuesday = @comment.voptions.create!(account: @member, text: 'Tuesday')
    tuesday.votes.create!(account: @member)

    sign_in_with_rack(create_member(name: 'Fence Sitter'))
    xhr :post, "/voptions/#{tuesday.id}/vote"
    assert last_response.ok?
    assert_equal [@member.id], tuesday.votes.pluck(:account_id)
  end

  test 'only the person who added a poll option can remove it' do
    team_thread
    tuesday = @comment.voptions.create!(account: @member, text: 'Tuesday')

    sign_in_with_rack(create_member(name: 'Other Member'))
    xhr :post, "/voptions/#{tuesday.id}/destroy"
    assert_refused
    assert Voption.find(tuesday.id)

    sign_in_with_rack(@member)
    xhr :post, "/voptions/#{tuesday.id}/destroy"
    assert last_response.ok?
    assert_nil Voption.find(tuesday.id)
  end

  # Files

  test "only a comment's author can attach a file to it, and not one a browser would run" do
    team_thread
    sign_in_with_rack(create_member(name: 'Other Member'))
    post "/comments/#{@comment.id}/file", file: upload('notes.txt')
    assert_refused
    assert_nil @comment.reload.file_uid

    sign_in_with_rack(@member)
    post "/comments/#{@comment.id}/file", file: upload('page.html')
    assert last_response.redirect?
    assert_nil @comment.reload.file_uid

    post "/comments/#{@comment.id}/file", file: upload('notes.txt')
    assert last_response.redirect?
    assert @comment.reload.file_uid
  end

  test "a comment's author who has left the discussion can't attach a file to it" do
    team_thread
    @gathering.memberships.find_by(account: @member).destroy
    sign_in_with_rack(@member)

    post "/comments/#{@comment.id}/file", file: upload('notes.txt')
    assert last_response.redirect?
    assert_nil @comment.reload.file_uid
  end

  # Sending a comment by email

  test "a gathering's admins can send a comment to the thread's subscribers, once" do
    team_thread
    @member.set(has_signed_in: true)
    subscriber = create_member(name: 'Subscriber', has_signed_in: true)
    @post.subscriptions.find_or_create_by!(account: subscriber)
    unsubscribed = create_member(name: 'Unsubscribed', has_signed_in: true, unsubscribed: true)
    @post.subscriptions.find_or_create_by!(account: unsubscribed)
    # Joining the team subscribed them to its threads: this one they've turned off
    bystander = create_member(name: 'Bystander', has_signed_in: true)
    @post.subscriptions.and(account: bystander).destroy_all
    comment = @post.comments.create!(account: @member, body: 'Please read')
    Delayed::Job.delete_all

    sign_in_with_rack(@account)
    post "/comments/#{comment.id}/send"
    assert last_response.redirect?
    emails = emails_sent_by_jobs(/send_comment/)
    assert_equal 1, emails.length
    assert_includes emails.first.recipients, subscriber.email
    assert_includes emails.first.recipients, @member.email
    refute_includes emails.first.recipients, unsubscribed.email
    refute_includes emails.first.recipients, bystander.email
    assert comment.reload.sent_at

    Delayed::Job.delete_all
    post "/comments/#{comment.id}/send"
    assert_empty emails_sent_by_jobs(/send_comment/)
  end

  test "a comment's author can't send it unless they're an admin of its gathering" do
    team_thread
    sign_in_with_rack(@member)
    Delayed::Job.delete_all

    post "/comments/#{@comment.id}/send"
    assert_refused
    assert_equal 0, Delayed::Job.count
  end

  test "nobody sends an event's chat comment by hand, not even the event's organiser" do
    create_event(prices: [0])
    comment = @event.discussion_post!(@account).comments.create!(account: @account, commentable: @event, body: 'Welcome')
    sign_in_with_rack(@account)
    Delayed::Job.delete_all

    post "/comments/#{comment.id}/send"
    assert_refused
    assert_equal 0, Delayed::Job.count
  end
end
