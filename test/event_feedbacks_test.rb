require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class EventFeedbacksTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def create_attended_event
    create_full_event_hierarchy(event_options: { prices: [0] })
    @attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: @attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
  end

  def create_feedback(account:, event: @event, rating: 3)
    event.event_feedbacks.create!(account: account, rating: rating)
  end

  def follow_redirects
    follow_redirect! while last_response.redirect?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Public lists show deleted rows as Removed; admin lists hide them
  # ═══════════════════════════════════════════════════════════════════════════

  test 'public activity and organisation lists show deleted feedback as Removed' do
    create_attended_event
    reviewer = FactoryBot.create(:account, name: 'Removed Reviewer')
    live_reviewer = FactoryBot.create(:account, name: 'Live Reviewer')
    deleted = create_feedback(account: reviewer)
    deleted.destroy
    create_feedback(account: live_reviewer, rating: 5)

    get "/activities/#{@activity.id}/show_feedback", minimal: 1
    assert_equal 200, last_response.status
    assert_includes last_response.body, '<em>Removed</em>'
    assert_includes last_response.body, @event.name

    get "/o/#{@organisation.slug}/show_feedback", minimal: 1
    assert_equal 200, last_response.status
    assert_includes last_response.body, '<em>Removed</em>'
    assert_includes last_response.body, @event.name
  end

  test 'admin event feedback page hides deleted feedback' do
    create_attended_event
    reviewer = FactoryBot.create(:account, name: 'Removed Reviewer')
    live_reviewer = FactoryBot.create(:account, name: 'Live Reviewer')
    deleted = create_feedback(account: reviewer)
    deleted.destroy
    create_feedback(account: live_reviewer, rating: 5)

    sign_in_with_rack(@account)
    get "/events/#{@event.id}/feedback"
    assert_equal 200, last_response.status
    refute_includes last_response.body, '<em>Removed</em>'
    refute_includes last_response.body, reviewer.name
    assert_includes last_response.body, live_reviewer.name
  end

  test 'event page still shows the activity feedback card when every rating has been removed' do
    create_attended_event
    create_feedback(account: @attendee).destroy

    get "/e/#{@event.slug}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Feedback on #{@activity.name} events"
    assert_includes last_response.body, "/activities/#{@activity.id}/show_feedback"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Submitting feedback
  # ═══════════════════════════════════════════════════════════════════════════

  test 'an attendee can leave feedback' do
    create_attended_event
    sign_in_with_rack(@attendee)

    post "/events/#{@event.id}/give_feedback", event_feedback: { rating: 4 }
    follow_redirects

    assert_includes last_response.body, 'Thanks for your feedback!'
    assert_equal 1, @event.event_feedbacks.count
    assert_equal 4, @event.event_feedbacks.first.rating
  end

  test 'a second live submission is rejected and not thanked' do
    create_attended_event
    create_feedback(account: @attendee, rating: 3)
    sign_in_with_rack(@attendee)

    post "/events/#{@event.id}/give_feedback", event_feedback: { rating: 1 }
    follow_redirects

    refute_includes last_response.body, 'Thanks for your feedback!'
    assert_includes last_response.body, "You've already left feedback on that event"
    assert_equal 1, @event.event_feedbacks.count
    assert_equal 1, EventFeedback.unscoped.and(event: @event, account: @attendee).count
  end

  test 'an attendee can leave new feedback after the first is deleted' do
    create_attended_event
    create_feedback(account: @attendee, rating: 3).destroy
    sign_in_with_rack(@attendee)

    post "/events/#{@event.id}/give_feedback", event_feedback: { rating: 5 }
    follow_redirects

    assert_includes last_response.body, 'Thanks for your feedback!'
    assert_equal 1, @event.event_feedbacks.count
    assert_equal 5, @event.event_feedbacks.first.rating
    assert_equal 2, EventFeedback.unscoped.and(event: @event, account: @attendee).count
  end

  test 'a second piece of live feedback on the same event is invalid' do
    create_attended_event
    create_feedback(account: @attendee, rating: 3)
    duplicate = @event.event_feedbacks.new(account: @attendee, rating: 1)

    refute duplicate.valid?
    assert_includes duplicate.errors.full_messages.to_sentence, 'already has your feedback'
  end

  test 'a failed save surfaces the error instead of thanking the attendee' do
    create_attended_event
    sign_in_with_rack(@attendee)
    header 'HTTP_REFERER', "/events/#{@event.id}/give_feedback"

    original = EventFeedback.instance_method(:save)
    EventFeedback.define_method(:save) do |*_args|
      errors.add(:base, 'could not be saved')
      false
    end
    begin
      post "/events/#{@event.id}/give_feedback", event_feedback: { rating: 2 }
      follow_redirects
      refute_includes last_response.body, 'Thanks for your feedback!'
      assert_includes last_response.body, 'could not be saved'
      assert_equal 0, EventFeedback.unscoped.count
    ensure
      EventFeedback.define_method(:save, original)
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Counts
  # ═══════════════════════════════════════════════════════════════════════════

  test 'facilitator count ignores deleted and unrated feedback' do
    create_attended_event
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)

    unrated_attendee = FactoryBot.create(:account)
    deleted_attendee = FactoryBot.create(:account)
    create_feedback(account: @attendee, rating: 4)
    create_feedback(account: unrated_attendee, rating: nil)
    create_feedback(account: deleted_attendee, rating: 2).destroy

    EventFeedback.update_event_feedbacks_as_facilitator_details
    assert_equal 1, facilitator.reload.event_feedbacks_as_facilitator_count
  end
end
