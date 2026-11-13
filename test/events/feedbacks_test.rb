require_relative '../test_config'

class EventFeedbacksTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  def create_attended_event
    create_full_event_hierarchy(event_options: { prices: [0] })
    @attendee = FactoryBot.create(:account)
    @event.tickets.create!(account: @attendee, ticket_type: @event.ticket_types.first, payment_completed: true)
  end

  def create_feedback(account:, event: @event, rating: 3)
    event.event_feedbacks.create!(account: account, rating: rating)
  end

  def feedback_entries
    Capybara.string(last_response.body).all('.feedback-entry')
  end

  test 'rating must be between 1 and 5' do
    create_attended_event
    [0, 6, -1_000_000, 1_000_000_000].each do |rating|
      refute @event.event_feedbacks.build(account: @attendee, rating: rating).valid?, "rating #{rating} should be invalid"
    end
    [nil, 1, 5].each do |rating|
      assert @event.event_feedbacks.build(account: @attendee, rating: rating).valid?, "rating #{rating.inspect} should be valid"
    end
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Public lists show deleted rows as Removed; admin lists hide them
  # ═══════════════════════════════════════════════════════════════════════════

  test 'public activity and organisation lists show deleted feedback as Removed' do
    covers 'events/deleted-feedback-removed-on-public-pages@6a15d2'
    covers_route 'GET /o/:slug/show_feedback'
    create_attended_event
    reviewer = FactoryBot.create(:account, name: 'Removed Reviewer')
    live_reviewer = FactoryBot.create(:account, name: 'Live Reviewer')
    deleted = create_feedback(account: reviewer)
    deleted.destroy
    create_feedback(account: live_reviewer, rating: 5)

    get "#{@activity.path}/show_feedback", minimal: 1
    assert_equal 200, last_response.status
    assert_includes last_response.body, '<em>Removed</em>'
    assert_includes last_response.body, @event.name

    get "/o/#{@organisation.slug}/show_feedback", minimal: 1
    assert_equal 200, last_response.status
    assert_includes last_response.body, '<em>Removed</em>'
    assert_includes last_response.body, @event.name
  end

  test 'deleted feedback on public pages keeps the reviewer\'s name and date' do
    covers 'events/deleted-feedback-removed-on-public-pages@6a15d2'
    create_attended_event
    reviewer = FactoryBot.create(:account, name: 'Removed Reviewer', has_signed_in: true)
    deleted = create_feedback(account: reviewer)
    deleted.set(created_at: 3.days.ago)
    deleted.destroy

    ["#{@activity.path}/show_feedback", "/o/#{@organisation.slug}/show_feedback"].each do |path|
      get path, minimal: 1
      assert_equal 200, last_response.status
      entry = feedback_entries.detect { |node| node.has_css?('em', text: 'Removed') }
      assert entry, path
      assert entry.has_link?('Removed Reviewer'), path
      assert_equal EventFeedback.unscoped.find(deleted.id).created_at.to_i, Time.parse(entry.find('relative-time')['datetime']).to_i, path
    end
  end

  test 'public feedback shows the average and star breakdown, then every rating newest first with its extract and reply' do
    covers 'events/public-feedback-summary@bdba04', 'events/public-feedback-reply-needs-extract@7877ec'
    create_attended_event
    oldest = FactoryBot.create(:account, name: 'Oldest Reviewer', has_signed_in: true)
    middle = FactoryBot.create(:account, name: 'Middle Reviewer', has_signed_in: true)
    newest = FactoryBot.create(:account, name: 'Newest Reviewer', has_signed_in: true)
    @event.event_feedbacks.create!(account: oldest, rating: 5, publicly_visible: true, answers: [['How was it?', 'Wonderful day. Kind teacher.']],
                                   public_answers: [['How was it?', 'Wonderful day.']], response: 'Thanks for coming!').set(created_at: 3.days.ago)
    create_feedback(account: middle, rating: 4).set(created_at: 2.days.ago)
    create_feedback(account: newest, rating: 2).set(created_at: 1.day.ago)

    get "#{@activity.path}/show_feedback", minimal: 1
    assert_equal 200, last_response.status
    page_html = Capybara.string(last_response.body)
    assert page_html.has_css?('.rating-breakdown-average', text: '3.7')
    assert page_html.has_css?('.rating-breakdown', text: '3 ratings')
    { 5 => 1, 4 => 1, 3 => 0, 2 => 1, 1 => 0 }.each do |stars, count|
      assert page_html.has_css?(".rating-breakdown-row[title='#{count} #{stars}-star #{count == 1 ? 'rating' : 'ratings'}']"), "#{stars} stars"
    end
    assert last_response.body.index('rating-breakdown') < last_response.body.index('feedback-entry')

    entries = feedback_entries
    reviewer_names = entries.map { |entry| entry.find('a[href^="/u/"]').text }
    assert_equal ['Newest Reviewer', 'Middle Reviewer', 'Oldest Reviewer'], reviewer_names
    assert entries.last.has_content?('Wonderful day.')
    assert entries.last.has_no_content?('Kind teacher.')
    assert entries.last.has_css?('.feedback-reply', text: 'Thanks for coming!')
    assert entries.first.has_no_css?('.feedback-reply')
  end

  test 'public feedback shows a reply only under ratings that have a public extract' do
    covers 'events/public-feedback-reply-needs-extract@7877ec'
    covers_route 'GET /o/:organisation_slug/a/:slug/show_feedback'
    create_attended_event
    quoted = FactoryBot.create(:account, name: 'Quoted Reviewer', has_signed_in: true)
    unquoted = FactoryBot.create(:account, name: 'Unquoted Reviewer', has_signed_in: true)
    @event.event_feedbacks.create!(account: quoted, rating: 5, publicly_visible: true, answers: [['How was it?', 'Wonderful day.']],
                                   public_answers: [['How was it?', 'Wonderful day.']], response: 'Thanks, quoted!').set(created_at: 2.days.ago)
    @event.event_feedbacks.create!(account: unquoted, rating: 4, publicly_visible: true, answers: [['How was it?', 'Good.']],
                                   response: 'Thanks, unquoted!').set(created_at: 1.day.ago)

    get "#{@activity.path}/show_feedback", minimal: 1
    assert_equal 200, last_response.status
    entries = feedback_entries
    assert_equal(['Unquoted Reviewer', 'Quoted Reviewer'], entries.map { |entry| entry.find('a[href^="/u/"]').text })
    assert entries.last.has_css?('.feedback-reply', text: 'Thanks, quoted!')
    assert entries.first.has_no_css?('.feedback-reply')
    refute_includes last_response.body, 'Thanks, unquoted!'
  end

  test 'public lists and the event page leave out feedback on secret events' do
    create_attended_event
    facilitator = FactoryBot.create(:account)
    create_event(as: :secret_event, activity: @activity, secret: true, name: 'Hidden Gathering')
    [@event, @secret_event].each { |event| event.event_facilitations.create!(account: facilitator) }
    reviewer = FactoryBot.create(:account, name: 'Secret Reviewer')
    event_feedback = create_feedback(account: reviewer, event: @secret_event, rating: 5)

    assert_equal 0, event_feedback.notifications.count
    ["#{@activity.path}/show_feedback", "/o/#{@organisation.slug}/show_feedback", "/u/#{facilitator.username}/show_feedback"].each do |path|
      get path, minimal: 1
      assert_equal 200, last_response.status
      refute_includes last_response.body, reviewer.name, path
      refute_includes last_response.body, @secret_event.name, path
    end

    get "/e/#{@event.slug}"
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'id="feedback"'
  end

  test 'making an event secret removes its feedback notifications' do
    create_attended_event
    event_feedback = create_feedback(account: @attendee, rating: 5)
    assert_equal 1, event_feedback.notifications.count

    @event.update!(secret: true)

    assert_equal 0, event_feedback.notifications.count
  end

  test "a feedback notification links to the reviewer once its event is gone" do
    create_attended_event
    event_feedback = create_feedback(account: @attendee, rating: 5)
    notification = event_feedback.notifications.first
    assert_equal ['View event', "#{ENV['BASE_URI']}/e/#{@event.slug}"], notification.link

    event_feedback.set(event_id: nil)
    assert_equal ['View profile', "#{ENV['BASE_URI']}/u/#{@attendee.username}"], Notification.find(notification.id).link
  end

  test 'admin event feedback page hides deleted feedback' do
    covers 'events/deleted-feedback-hidden-from-admin@140b84'
    create_attended_event
    reviewer = FactoryBot.create(:account, name: 'Removed Reviewer')
    live_reviewer = FactoryBot.create(:account, name: 'Live Reviewer')
    deleted = create_feedback(account: reviewer)
    deleted.destroy
    create_feedback(account: live_reviewer, rating: 5)

    sign_in_with_rack(@account)
    get "/e/#{@event.slug}/feedback"
    assert_equal 200, last_response.status
    refute_includes last_response.body, '<em>Removed</em>'
    refute_includes last_response.body, reviewer.name
    assert_includes last_response.body, live_reviewer.name
  end

  test 'site admins can list and respond to feedback on an event whose organisation was deleted' do
    covers_route 'GET /event_feedbacks/:id/response'
    covers_route 'GET /stats/feedback'
    create_attended_event
    feedback = create_feedback(account: @attendee)
    @event.set(organisation_id: nil)

    sign_in_with_rack(FactoryBot.create(:account, admin: true))
    get '/stats/feedback'
    assert_equal 200, last_response.status
    assert_includes last_response.body, "The organiser's public response to this feedback"

    get "/event_feedbacks/#{feedback.id}/response"
    assert_equal 200, last_response.status
  end

  test 'single feedback page shows the attendee email only to email viewers' do
    covers 'organisations/attendee-emails-admins-and-managers-only@10b712'
    covers_route 'GET /event_feedbacks/:id'
    create_attended_event
    @event.update!(show_emails: false)
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    event_feedback = create_feedback(account: @attendee)

    sign_in_with_rack(facilitator)
    get "/event_feedbacks/#{event_feedback.id}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, @attendee.name
    refute_includes last_response.body, @attendee.email

    sign_in_with_rack(@account)
    get "/event_feedbacks/#{event_feedback.id}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, @attendee.email
  end

  test 'on phones, a feedback row shows its hidden columns when opened' do
    create_attended_event
    @event.event_feedbacks.create!(account: @attendee, rating: 4, answers: [['How was it?', 'Lovely day']])

    sign_in(@account)
    page.current_window.resize_to(375, 812)
    visit "/e/#{@event.slug}/feedback"
    assert page.has_css?('#event_feedbacks .feedback-toggle')
    assert page.has_no_content?('Lovely day')

    find('#event_feedbacks .feedback-toggle').click
    assert page.has_css?('#event_feedbacks .feedback-details', text: 'Answers')
    assert page.has_content?('Lovely day')

    find('#event_feedbacks .feedback-toggle').click
    assert page.has_css?('#event_feedbacks .feedback-toggle[aria-expanded="false"]')
    assert page.has_no_content?('Lovely day')
  ensure
    page.current_window.resize_to(1280, 720)
  end

  test 'event page still shows the activity feedback card when every rating has been removed' do
    create_attended_event
    create_feedback(account: @attendee).destroy

    get "/e/#{@event.slug}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, "Feedback on #{@activity.name} events"
    assert_includes last_response.body, "#{@activity.path}/show_feedback"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Submitting feedback
  # ═══════════════════════════════════════════════════════════════════════════

  def visit_feedback_form
    create_attended_event
    sign_in(@attendee)
    visit "/e/#{@event.slug}/give_feedback"
    assert page.has_css?('.feedback-stars label', count: 5)
  end

  def assert_rating(rating)
    assert page.has_css?("#event_feedback_rating_#{rating}:checked", visible: :all)
    assert page.has_css?('.feedback-stars label.chosen', count: rating)
  end

  # A tap as a touch screen sends it, through Chrome's touch emulation
  def tap_on(node)
    browser_page = page.driver.browser.page
    page.scroll_to(node, align: :center)
    rect = evaluate_script('arguments[0].getBoundingClientRect().toJSON()', node)
    point = { x: rect['x'] + (rect['width'] / 2), y: rect['y'] + (rect['height'] / 2) }
    browser_page.command('Emulation.setTouchEmulationEnabled', enabled: true, maxTouchPoints: 1)
    browser_page.command('Input.dispatchTouchEvent', type: 'touchStart', touchPoints: [point])
    browser_page.command('Input.dispatchTouchEvent', type: 'touchEnd', touchPoints: [])
  ensure
    browser_page&.command('Emulation.setTouchEmulationEnabled', enabled: false)
  end

  test 'an attendee can choose a star rating with the mouse and submit it' do
    covers 'events/attendees-give-feedback@24ba67'
    covers_route 'GET /donate'
    visit_feedback_form

    find('label[for="event_feedback_rating_4"]').hover
    assert page.has_css?('.feedback-stars label.chosen', count: 4)
    find('label[for="event_feedback_rating_4"]').click
    assert_rating(4)

    click_button 'Submit feedback'
    assert page.has_content?('Thanks for your feedback!')
    assert_equal 1, @event.event_feedbacks.count
    assert_equal 4, @event.event_feedbacks.first.rating
  end

  def submit_rating(rating)
    find("label[for=\"event_feedback_rating_#{rating}\"]").click
    assert_rating(rating)
    click_button 'Submit feedback'
  end

  test 'an attendee can choose a star rating with a tap' do
    visit_feedback_form

    tap_on(find('label[for="event_feedback_rating_2"]'))
    assert_rating(2)
  end

  test 'an attendee can choose a star rating with the keyboard' do
    visit_feedback_form

    # Focus lands on the first star as Tab would (send_keys clicks the node first, and the radio is under its star)
    execute_script("document.getElementById('event_feedback_rating_1').focus()")
    keyboard = page.driver.browser.keyboard
    keyboard.type(:space)
    assert_rating(1)
    keyboard.type(:right, :right)
    assert_rating(3)
    assert page.has_css?('#event_feedback_rating_3:focus', visible: :all)
  end

  test 'a second live submission is rejected and not thanked' do
    visit_feedback_form
    create_feedback(account: @attendee, rating: 3)

    submit_rating(1)
    assert page.has_content?("You've already left feedback on that event")
    assert page.has_no_content?('Thanks for your feedback!')
    assert_equal 1, @event.event_feedbacks.count
    assert_equal 1, EventFeedback.unscoped.and(event: @event, account: @attendee).count
  end

  test 'an attendee can leave new feedback after the first is deleted' do
    visit_feedback_form
    create_feedback(account: @attendee, rating: 3).destroy

    submit_rating(5)
    assert page.has_content?('Thanks for your feedback!')
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
    visit_feedback_form

    original = EventFeedback.instance_method(:save)
    EventFeedback.define_method(:save) do |*_args|
      errors.add(:base, 'could not be saved')
      false
    end
    begin
      submit_rating(2)
      assert page.has_content?('could not be saved')
      assert page.has_no_content?('Thanks for your feedback!')
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
    @event.set(start_time: 2.days.ago, end_time: 1.day.ago)

    EventFeedback.update_event_feedbacks_as_facilitator_details
    facilitator.reload
    assert_equal 1, facilitator.event_feedbacks_as_facilitator_count
    assert_in_delta 4.0, facilitator.event_feedbacks_as_facilitator_average_rating
    assert_equal 1, facilitator.past_events_as_facilitator_count
  end

  test 'facilitators appear on the Facilitators page once they have received feedback' do
    covers 'events/facilitators-page-after-feedback@4c0000', 'organisations/facilitator-listed-emailed-opt-in@29059a'
    covers_route 'GET /facilitators'
    create_attended_event
    facilitator = FactoryBot.create(:account, name: 'Rated Facilitator')
    unrated_facilitator = FactoryBot.create(:account, name: 'Unrated Facilitator')
    @event.event_facilitations.create!(account: facilitator)
    create_event(as: :other_event, activity: @activity)
    @other_event.event_facilitations.create!(account: unrated_facilitator)
    EventFeedback.update_event_feedbacks_as_facilitator_details

    get '/facilitators'
    assert_equal 200, last_response.status
    refute_includes last_response.body, 'Rated Facilitator'

    create_feedback(account: @attendee, rating: 5)
    EventFeedback.update_event_feedbacks_as_facilitator_details

    get '/facilitators'
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Rated Facilitator'
    refute_includes last_response.body, 'Unrated Facilitator'
  end

  test 'organisers can resend the feedback email from the Orders page' do
    covers 'events/resend-feedback-email@c5b06a'
    covers_route 'POST /e/:slug/resend_feedback_email/:account_id'
    create_full_event_hierarchy(event_options: { prices: [0], feedback_questions: 'How was it?' })
    @event.set(start_time: 2.days.ago, end_time: 1.day.ago)
    attendee = FactoryBot.create(:account)
    order = Order.create!(event: @event, account: attendee, value: 0, payment_completed: true, currency: 'GBP')
    @event.ticket_types.first.tickets.create!(event: @event, order: order, account: attendee, payment_completed: true, price: 0)
    other_attendee = FactoryBot.create(:account)
    @event.ticket_types.first.tickets.create!(event: @event, account: other_attendee, payment_completed: true, price: 0)
    sign_in(@account)

    visit "/e/#{@event.slug}/orders"
    assert page.has_link?('Resend feedback email', href: "/e/#{@event.slug}/resend_feedback_email/#{attendee.id}")

    Delayed::Job.delete_all
    click_link 'Resend feedback email'
    assert page.has_content?('The feedback email was resent.')

    emails = emails_sent_by_jobs(/send_feedback_requests/)
    assert_equal [[attendee.email]], emails.map(&:recipients)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Public extracts
  # ═══════════════════════════════════════════════════════════════════════════

  def run_public_answer_jobs(extract)
    OpenRouter.stub :chat, extract do
      Delayed::Job.and(handler: /generate_public_answers/).each(&:invoke_job)
    end
  end

  test 'an extract is suggested for 5-star single-question feedback that may be quoted publicly' do
    covers 'events/public-extract-suggested@9c5eec'
    create_attended_event
    Delayed::Job.delete_all
    answer = 'It was a wonderful day. The teacher was kind and the room was too cold.'
    feedback = @event.event_feedbacks.create!(account: @attendee, rating: 5, publicly_visible: true, answers: [['How was it?', answer]])
    [
      { rating: 4, publicly_visible: true, answers: [['How was it?', answer]] },
      { rating: 5, publicly_visible: false, answers: [['How was it?', answer]] },
      { rating: 5, publicly_visible: true, answers: [['How was it?', answer], ['Anything else?', answer]] }
    ].each { |attributes| @event.event_feedbacks.create!(account: FactoryBot.create(:account), **attributes) }
    assert_equal 1, Delayed::Job.and(handler: /generate_public_answers/).count

    run_public_answer_jobs('"The teacher was kind and the room was too cold."')
    assert_equal [['How was it?', 'The teacher was kind and the room was too cold.']], feedback.reload.public_answers

    # The feedback table shows each extract with the page, rather than loading it
    sign_in(@account)
    visit "/e/#{@event.slug}/feedback"
    extract = "[data-pagelet-url='/event_feedbacks/#{feedback.id}/public_answers/0']"
    within(extract) do
      assert page.has_field?('Public extract', with: 'The teacher was kind and the room was too cold.')
      assert page.has_no_link?('Show an extract')
      fill_in 'Public extract', with: 'It was a wonderful day.'
      find('button[aria-label="Save extract"]').click
    end
    page.document.synchronize do
      raise Capybara::ExpectationNotMet, 'extract not saved yet' unless feedback.reload.public_answers == [['How was it?', 'It was a wonderful day.']]
    end
    assert page.has_field?('Public extract', with: 'It was a wonderful day.')
  end

  test 'no extract is suggested when the answer has nothing to quote' do
    covers 'events/public-extract-suggested@9c5eec'
    covers_route 'GET /event_feedbacks/:id/public_answers/:i'
    create_attended_event
    answer = 'It was a wonderful day.'
    ['', 'Best course ever, highly recommended!'].each do |extract|
      EventFeedback.unscoped.delete_all
      Delayed::Job.delete_all
      feedback = @event.event_feedbacks.create!(account: @attendee, rating: 5, publicly_visible: true, answers: [['How was it?', answer]])
      assert_equal 1, Delayed::Job.and(handler: /generate_public_answers/).count
      run_public_answer_jobs(extract)
      assert_nil feedback.reload.public_answers, extract
    end

    sign_in_with_rack(@account)
    get "/event_feedbacks/#{EventFeedback.first.id}/public_answers/0"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Show an extract'
  end

  test 'feedback that may not be quoted publicly has no extract control' do
    covers 'events/no-extract-control-not-public@82dbfb'
    create_attended_event
    public_feedback = @event.event_feedbacks.create!(account: @attendee, rating: 4, publicly_visible: true, answers: [['How was it?', 'Quotable answer']])
    private_feedback = @event.event_feedbacks.create!(account: FactoryBot.create(:account), rating: 4, publicly_visible: false, answers: [['How was it?', 'Private answer']])
    sign_in_with_rack(@account)

    get "/e/#{@event.slug}/feedback"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Private answer'
    assert_includes last_response.body, "/event_feedbacks/#{public_feedback.id}/public_answers/0"
    refute_includes last_response.body, "/event_feedbacks/#{private_feedback.id}/public_answers"

    get "/event_feedbacks/#{private_feedback.id}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'Private answer'
    refute_includes last_response.body, "/event_feedbacks/#{private_feedback.id}/public_answers"
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Summaries
  # ═══════════════════════════════════════════════════════════════════════════

  test 'feedback summaries render markdown but not script links or HTML' do
    account = FactoryBot.build(:account, feedback_summary: 'Loved **this** [read more](javascript:alert(1)), see [site](https://example.com) <img src=x onerror=alert(1)>')

    html = account.feedback_summary_html

    assert_includes html, '<strong>this</strong>'
    assert_includes html, '<a href="https://example.com">site</a>'
    refute_includes html, 'href="javascript:'
    refute_includes html, '<img'
  end

  def create_five_answered_feedbacks
    create_attended_event
    5.times { @event.event_feedbacks.create!(account: FactoryBot.create(:account), rating: 5, answers: [['How was it?', 'Lovely']]) }
  end

  test "an event's improvement report lists what the feedback points to" do
    create_five_answered_feedbacks
    sign_in(@account)
    OpenRouter.stub :chat, "1. You could start on time.\n\n2. You could open the windows." do
      visit "/e/#{@event.slug}/feedback"
      assert page.has_content?('here are up to 5 possible areas for improvement')
      assert page.has_css?('li', text: 'You could start on time.')
      assert page.has_css?('li', text: 'You could open the windows.')
    end
  end

  test "an event's improvement report says so when the feedback points to nothing to improve" do
    create_five_answered_feedbacks
    sign_in(@account)
    OpenRouter.stub :chat, 'NONE' do
      visit "/e/#{@event.slug}/feedback"
      assert page.has_content?("The feedback doesn't point to anything to improve.")
      assert page.has_no_content?('possible areas for improvement')
    end
  end
end
