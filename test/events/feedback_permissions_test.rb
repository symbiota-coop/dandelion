require_relative '../test_config'

# Who can give feedback on an event, who can read it, and who can respond to, quote or delete it: forged requests the
# UI can't make, so all through Rack. That anonymous feedback never names its author is checked on every page, export
# and email that shows feedback
class EventFeedbackPermissionsTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def setup
    create_full_event_hierarchy(event_options: { prices: [0] })
    @attendee = FactoryBot.create(:account, name: 'Hidden Reviewer', email: 'hidden.reviewer@example.com')
    @event.tickets.create!(account: @attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
  end

  def create_feedback(account: @attendee, event: @event, **attrs)
    event.event_feedbacks.create!(account: account, rating: 4, answers: [['How was it?', 'Private thoughts here']], **attrs)
  end

  def feedback_params(rating: 4)
    { event_feedback: { rating: rating }, questions: { '0' => 'How was it?' }, answers: { '0' => 'Lovely' } }
  end

  def create_facilitator
    FactoryBot.create(:account, name: 'Event Facilitator').tap { |facilitator| @event.event_facilitations.create!(account: facilitator) }
  end

  def assert_kicked
    assert last_response.redirect?, "expected a redirect, got #{last_response.status}"
    refute_includes last_response.body, 'Private thoughts here'
  end

  def refute_reveals_attendee(body)
    refute_includes body, @attendee.name
    refute_includes body, @attendee.email
    refute_includes body, "/u/#{@attendee.username}"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Giving feedback
  # ═══════════════════════════════════════════════════════════════════════════

  test 'only someone with a completed ticket to the event can give feedback on it' do
    unpaid = FactoryBot.create(:account)
    # A free ticket completes on save: this one stands for a paid ticket whose payment hasn't come through
    @event.tickets.create!(account: unpaid, ticket_type: @event.ticket_types.first).set(payment_completed: false)
    other_event_attendee = FactoryBot.create(:account)
    create_event(as: :other_event, prices: [0])
    @other_event.tickets.create!(account: other_event_attendee, ticket_type: @other_event.ticket_types.first, payment_completed: true)

    [FactoryBot.create(:account), unpaid, other_event_attendee].each do |account|
      sign_in_with_rack(account)
      get "/e/#{@event.slug}/give_feedback"
      assert last_response.redirect?
      post "/e/#{@event.slug}/give_feedback", feedback_params
      assert_equal "/o/#{@organisation.slug}/events", URI(last_response.location).path
    end
    assert_equal 0, @event.event_feedbacks.count

    sign_in_with_rack(@attendee)
    post "/e/#{@event.slug}/give_feedback", feedback_params
    assert_equal 1, @event.event_feedbacks.count
    assert_equal @attendee, @event.event_feedbacks.first.account
  end

  test 'signed out, feedback needs a feedback token' do
    covers_route 'POST /e/:slug/give_feedback'
    post "/e/#{@event.slug}/give_feedback", feedback_params
    assert_kicked
    assert_equal 0, EventFeedback.count
  end

  test "a feedback token gives feedback as its own attendee on its own event, and no other's" do
    create_event(as: :other_event, prices: [0])
    @other_event.tickets.create!(account: @attendee, ticket_type: @other_event.ticket_types.first, payment_completed: true)
    token = @attendee.feedback_token_for(@other_event)

    # Another event's token, a tampered one, and one with no signature are refused, even when signed in
    signed_in = FactoryBot.create(:account)
    sign_in_with_rack(signed_in)
    [token, "#{token}x", 'feedback'].each do |bad_token|
      post "/e/#{@event.slug}/give_feedback", feedback_params.merge(token: bad_token)
      assert last_response.redirect?
    end
    assert_equal 0, EventFeedback.count

    # The token's own event takes the feedback, as the token's attendee, not whoever is signed in
    post "/e/#{@other_event.slug}/give_feedback", feedback_params.merge(token: token)
    assert_equal 1, EventFeedback.count
    assert_equal [@attendee], @other_event.event_feedbacks.map(&:account)
    assert_equal 0, signed_in.event_feedbacks.count
  end

  test 'a feedback token for an account that did not attend gives no feedback' do
    stranger = FactoryBot.create(:account)
    post "/e/#{@event.slug}/give_feedback", feedback_params.merge(token: stranger.feedback_token_for(@event))
    assert last_response.redirect?
    assert_equal 0, EventFeedback.count
  end

  test "only site admins can give feedback for someone else by email" do
    sign_in_with_rack(@account) # the organisation's admin, not a site admin
    post "/e/#{@event.slug}/give_feedback", feedback_params.merge(email: @attendee.email)
    assert last_response.redirect?
    assert_equal 0, EventFeedback.count

    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    post "/e/#{@event.slug}/give_feedback", feedback_params.merge(email: @attendee.email)
    assert_equal [@attendee], @event.event_feedbacks.map(&:account)
  end

  test 'a forged account or event id in the form is ignored' do
    create_event(as: :other_event, prices: [0])
    other = FactoryBot.create(:account)
    sign_in_with_rack(@attendee)
    post "/e/#{@event.slug}/give_feedback", feedback_params.deep_merge(event_feedback: { account_id: other.id.to_s, event_id: @other_event.id.to_s })

    feedback = EventFeedback.find_by(account: @attendee)
    assert_equal @event, feedback.event
    assert_equal 0, other.event_feedbacks.count
    assert_equal 0, @other_event.event_feedbacks.count
  end

  test "the feedback form can't set the organiser's response or public extracts" do
    sign_in_with_rack(@attendee)
    { response: 'We agree, it was great', public_answers: [['How was it?', 'Fake quote']], has_public_answers: '1', answers: [['Q', 'A']] }.each do |field, value|
      error = assert_raises(RuntimeError) { post "/e/#{@event.slug}/give_feedback", feedback_params.deep_merge(event_feedback: { field => value }) }
      assert_match(/are protected/, error.message)
    end
    assert_equal 0, EventFeedback.count
  end

  test "an event's feedback preview token shows the form but can't submit feedback" do
    covers_route 'GET /e/:slug/give_feedback'
    token = @event.feedback_preview_token
    get "/e/#{@event.slug}/give_feedback", token: token
    assert_equal 200, last_response.status

    sign_in_with_rack(@attendee)
    post "/e/#{@event.slug}/give_feedback", feedback_params.merge(token: token)
    assert_equal 403, last_response.status
    assert_equal 0, EventFeedback.count

    # Nor does it preview another event's form
    create_event(as: :other_event)
    clear_cookies
    get "/e/#{@other_event.slug}/give_feedback", token: token
    assert last_response.redirect?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Reading feedback
  # ═══════════════════════════════════════════════════════════════════════════

  test "only the event's admins can read its feedback, as a page or CSV" do
    covers_route 'GET /e/:slug/feedback_report'
    feedback = create_feedback
    reviewer = FactoryBot.create(:account)
    @event.tickets.create!(account: reviewer, ticket_type: @event.ticket_types.first, payment_completed: true)
    create_feedback(account: reviewer)

    paths = ["/e/#{@event.slug}/feedback", "/e/#{@event.slug}/feedback.csv", "/event_feedbacks/#{feedback.id}", "/e/#{@event.slug}/feedback_report"]
    [nil, reviewer, FactoryBot.create(:account)].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      paths.each do |path|
        get path
        assert_kicked
      end
    end

    sign_in_with_rack(create_facilitator)
    get "/e/#{@event.slug}/feedback"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Private thoughts here'
    get "/e/#{@event.slug}/feedback.csv"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Private thoughts here'
  end

  test "only admins of an organisation, activity or local group can read its feedback list" do
    covers_route 'GET /o/:organisation_slug/a/:slug/feedback'
    covers_route 'GET /o/:organisation_slug/lg/:slug/feedback'
    covers_route 'GET /o/:slug/feedback'
    create_feedback
    paths = ["/o/#{@organisation.slug}/feedback", "#{@activity.path}/feedback", "/o/#{@organisation.slug}/lg/#{@local_group.slug}/feedback", '/stats/feedback']
    # A facilitator is an admin of the event, but not of its organisation, activity or local group
    [nil, @attendee, create_facilitator].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      paths.each do |path|
        get path
        assert_kicked
      end
    end

    sign_in_with_rack(@account)
    paths[0..2].each do |path|
      get path
      assert_equal 200, last_response.status, path
      assert_includes last_response.body, 'Private thoughts here', path
    end
  end

  test 'anonymous feedback never names its author to admins, in pages or the CSV' do
    feedback = create_feedback(anonymous: true)
    site_admin = FactoryBot.create(:account, admin: true)

    [@account, site_admin].each do |admin|
      sign_in_with_rack(admin)
      ["/e/#{@event.slug}/feedback", "/event_feedbacks/#{feedback.id}", "/o/#{@organisation.slug}/feedback", "#{@activity.path}/feedback",
       "/o/#{@organisation.slug}/lg/#{@local_group.slug}/feedback"].each do |path|
        get path
        assert_equal 200, last_response.status, path
        refute_reveals_attendee(last_response.body)
      end
      assert_includes last_response.body, @event.name

      # The tickets and orders tables name ticket holders, but don't link them to anonymous feedback
      ["/e/#{@event.slug}/orders", "/e/#{@event.slug}/tickets"].each do |path|
        get path
        assert_equal 200, last_response.status, path
        refute_includes last_response.body, "/event_feedbacks/#{feedback.id}", path
      end
      assert_includes last_response.body, @attendee.name

      get "/e/#{@event.slug}/feedback.csv"
      assert_equal 200, last_response.status
      refute_reveals_attendee(last_response.body)
      row = CSV.parse(last_response.body, headers: true).first
      assert_equal %w[Anonymous yes], [row['name'], row['anonymous']]
      assert_equal '', row['email'].to_s
    end
    get '/stats/feedback'
    assert_equal 200, last_response.status
    refute_reveals_attendee(last_response.body)
  end

  test "named feedback's CSV gives the author's email only to those who may see attendees' emails" do
    covers 'organisations/attendee-emails-admins-and-managers-only@10b712'
    covers_route 'GET /e/:slug/feedback'
    @event.update!(show_emails: false)
    create_feedback

    sign_in_with_rack(create_facilitator)
    get "/e/#{@event.slug}/feedback.csv"
    row = CSV.parse(last_response.body, headers: true).first
    assert_equal @attendee.name, row['name']
    assert_equal '', row['email'].to_s

    sign_in_with_rack(@account)
    get "/e/#{@event.slug}/feedback.csv"
    assert_equal @attendee.email, CSV.parse(last_response.body, headers: true).first['email']
  end

  test 'public feedback lists hide anonymous authors and show only the extracts chosen for them' do
    facilitator = create_facilitator
    create_feedback(anonymous: true, publicly_visible: true, public_answers: [['How was it?', 'Quotable line']])

    ["/o/#{@organisation.slug}/show_feedback?minimal=1", "#{@activity.path}/show_feedback?minimal=1", "/u/#{facilitator.username}/show_feedback",
     "/u/#{facilitator.username}/feedback"].each do |path|
      get path
      assert_equal 200, last_response.status, path
      assert_includes last_response.body, 'Anonymous', path
      assert_includes last_response.body, 'Quotable line', path
      refute_includes last_response.body, 'Private thoughts here', path
      refute_reveals_attendee(last_response.body)
    end
  end

  test 'anonymous feedback makes no feed notification and its emails name no one' do
    facilitator = create_facilitator
    emails = recorded_emails do
      create_feedback(anonymous: true, publicly_visible: true)
      Delayed::Job.and(handler: /send_feedback/).each(&:invoke_job)
    end
    assert_equal 0, Notification.and(type: 'left_feedback').count
    assert_equal 1, emails.length
    assert_includes emails.first.recipients, facilitator.email
    assert_includes emails.first.subject_line, 'Anonymous'
    refute_reveals_attendee("#{emails.first.subject_line} #{emails.first.html}")

    feedback = @event.event_feedbacks.first
    feedback.send_destroy_notification(@account)
    emails = emails_sent_by_jobs(/send_destroy_notification/)
    assert_equal 1, emails.length
    refute_reveals_attendee(emails.first.html)
  end

  test 'the facilitator feedback report and text are for signed-in facilitators, of their own events' do
    covers_route 'GET /event_feedbacks/feedback'
    covers_route 'GET /event_feedbacks/report'
    facilitator = create_facilitator
    create_feedback
    create_event(as: :other_event)
    stranger = FactoryBot.create(:account)
    @other_event.event_facilitations.create!(account: stranger)

    get '/event_feedbacks/report'
    assert last_response.redirect?
    get '/event_feedbacks/feedback.txt'
    assert last_response.redirect?

    sign_in_with_rack(stranger)
    get '/event_feedbacks/feedback.txt'
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'Private thoughts here'

    sign_in_with_rack(facilitator)
    get '/event_feedbacks/feedback.txt'
    assert_includes last_response.body, 'Private thoughts here'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Responding, quoting and deleting
  # ═══════════════════════════════════════════════════════════════════════════

  test "only the event's admins can respond to feedback or choose its public extract" do
    feedback = create_feedback(publicly_visible: true)
    [nil, @attendee, FactoryBot.create(:account)].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get "/event_feedbacks/#{feedback.id}/response"
      assert last_response.redirect?
      post "/event_feedbacks/#{feedback.id}/response", response: 'Forged reply'
      assert last_response.redirect?
      get "/event_feedbacks/#{feedback.id}/public_answers/0"
      assert last_response.redirect?
      post "/event_feedbacks/#{feedback.id}/public_answers/0", public_answer: 'Forged quote'
      assert last_response.redirect?
    end
    feedback.reload
    assert_nil feedback.response
    assert_nil feedback.public_answers

    sign_in_with_rack(create_facilitator)
    post "/event_feedbacks/#{feedback.id}/response", response: 'Thanks!'
    assert_equal 200, last_response.status
    post "/event_feedbacks/#{feedback.id}/public_answers/0", public_answer: 'Private thoughts'
    assert_equal 200, last_response.status
    feedback.reload
    assert_equal 'Thanks!', feedback.response
    assert_equal [['How was it?', 'Private thoughts']], feedback.public_answers
  end

  test "feedback that's anonymous and can't be quoted can't be responded to, and a response to anonymous feedback emails no one" do
    covers_route 'POST /event_feedbacks/:id/response'
    hidden = create_feedback(anonymous: true)
    sign_in_with_rack(@account)
    post "/event_feedbacks/#{hidden.id}/response", response: 'Reply'
    assert_equal 400, last_response.status
    assert_nil hidden.reload.response

    hidden.update!(publicly_visible: true)
    post "/event_feedbacks/#{hidden.id}/response", response: 'Reply'
    assert_equal 200, last_response.status
    assert_empty emails_sent_by_jobs(/send_response/)
  end

  test "feedback that may not be quoted publicly can't be given a public extract" do
    covers 'events/no-extract-control-not-public@82dbfb'
    covers_route 'POST /event_feedbacks/:id/public_answers/:i'
    feedback = create_feedback(publicly_visible: false)
    sign_in_with_rack(@account)
    get "/event_feedbacks/#{feedback.id}/public_answers/0"
    assert_equal 403, last_response.status
    post "/event_feedbacks/#{feedback.id}/public_answers/0", public_answer: 'Private thoughts here'
    assert_equal 403, last_response.status
    assert_nil feedback.reload.public_answers

    get "/o/#{@organisation.slug}/show_feedback", minimal: 1
    refute_includes last_response.body, 'Private thoughts here'
  end

  test "only the organisation's admins can delete feedback, and only site admins delete it for good" do
    covers_route 'POST /event_feedbacks/:id/destroy'
    covers_route 'POST /event_feedbacks/:id/hard_destroy'
    feedback = create_feedback
    [@attendee, create_facilitator].each do |account|
      sign_in_with_rack(account)
      post "/event_feedbacks/#{feedback.id}/destroy"
      assert last_response.redirect?
    end
    assert EventFeedback.find(feedback.id)

    sign_in_with_rack(@account)
    post "/event_feedbacks/#{feedback.id}/hard_destroy"
    assert last_response.redirect?
    assert EventFeedback.find(feedback.id)

    post "/event_feedbacks/#{feedback.id}/destroy"
    assert_nil EventFeedback.find(feedback.id)
    assert EventFeedback.unscoped.find(feedback.id).deleted_at

    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    post "/event_feedbacks/#{feedback.id}/hard_destroy"
    assert_nil EventFeedback.unscoped.find(feedback.id)
  end
end
