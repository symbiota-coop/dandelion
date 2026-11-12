require_relative '../test_config'

# Applying to an activity, who may see and decide applications, and following, editing and administering an activity
class OrganisationsActivityApplicationsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  QUESTION = 'Why do you want to join?'.freeze

  # @activity needs people to apply, and @account (the organisation's owner) is its admin
  def create_closed_activity(**attrs)
    create_organisation
    @activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'closed', application_questions: QUESTION, email: 'activity@example.com', **attrs)
  end

  def application_by(applicant, answer: 'To learn')
    @activity.activity_applications.create!(account: applicant, status: 'Pending', answers: [[QUESTION, answer]])
  end

  def assert_redirected_to(path)
    assert last_response.redirect?, "Expected a redirect to #{path}, got #{last_response.status}"
    assert_equal path, URI(last_response.location).path
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Deciding applications, in the browser
  # ═══════════════════════════════════════════════════════════════════════════

  test 'an admin opens an application from the list and accepts it, which makes the applicant a hidden follower and emails them' do
    covers 'organisations/application-only-activities@7b2afe'
    create_closed_activity
    applicant = FactoryBot.create(:account)
    application = application_by(applicant)

    sign_in(@account)
    visit "#{@activity.path}/applications"
    assert page.has_content? applicant.email
    find('td a', text: applicant.name).click
    assert page.has_content? "#{applicant.name}'s application to #{@activity.name}"
    assert page.has_content? 'To learn'

    emails = recorded_emails do
      select 'Accepted', from: 'status'
      assert page.has_content? "by #{@account.name}"
    end

    application.reload
    assert_equal 'Accepted', application.status
    assert_equal @account, application.statused_by
    activityship = @activity.activityships.find_by(account: applicant)
    assert activityship, 'The applicant should follow the activity'
    assert activityship.hide_membership?, "A closed activity shouldn't show on a new follower's profile"

    assert_equal 1, emails.length
    email = emails.first
    assert_equal [applicant.email], email.recipients
    assert_equal "You've been accepted to #{@activity.name}", email.subject_line
    assert_equal 'activity@example.com', email.reply_to_address
  end

  test "statuses other than Accepted don't make the applicant a follower or email them, and take the application out of the Pending list" do
    create_closed_activity
    applicant = FactoryBot.create(:account)
    application = application_by(applicant)

    sign_in(@account)
    visit "#{@activity.path}/activity_applications/#{application.id}"
    assert page.has_css? '.badge', exact_text: 'Pending'
    emails = recorded_emails do
      (ActivityApplication.statuses - %w[Pending Accepted]).each do |status|
        select status, from: 'status'
        assert page.has_css? '.badge', exact_text: status
        assert_equal status, application.reload.status
      end
    end
    assert_empty emails
    assert_nil @activity.activityships.find_by(account: applicant)
    assert_equal @account, application.reload.statused_by

    visit "#{@activity.path}/applications"
    assert page.has_link? 'Download CSV'
    assert page.has_no_content? applicant.email
    select 'Rejected, contacted (1)', from: 'status'
    assert page.has_content? applicant.email
  end

  test 'an applicant applies when signed in, then sees their latest application and can apply again' do
    create_closed_activity
    applicant = FactoryBot.create(:account)
    sign_in(applicant)
    visit @activity.path
    click_link 'Apply'
    fill_in 'answers[0]', with: 'I love it'
    click_button 'Apply'
    assert page.has_content? 'Thanks for applying'
    assert_equal 'Pending', @activity.activity_applications.find_by(account: applicant).status

    visit @activity.path
    assert page.has_link? 'Apply again'
    click_link 'View latest application'
    assert page.has_content? "#{applicant.name}'s application to #{@activity.name}"
    assert page.has_content? 'I love it'
    assert page.has_no_select? 'status'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Following, in the browser
  # ═══════════════════════════════════════════════════════════════════════════

  test 'a follower hides the activity from their profile and shows it again' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'open')
    follower = FactoryBot.create(:account)
    activityship = activity.activityships.create!(account: follower)

    sign_in(follower)
    visit activity.path
    click_link 'Showing on your profile'
    assert page.has_link? 'Not showing on your profile'
    assert activityship.reload.hide_membership?

    click_link 'Not showing on your profile'
    assert page.has_link? 'Showing on your profile'
    refute activityship.reload.hide_membership?
  end

  test 'an admin chooses whether they receive feedback' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    activityship = activity.activityships.find_by(account: @account)

    sign_in(@account)
    visit activity.path
    click_link 'Not receiving feedback'
    assert page.has_link? 'Receiving feedback'
    assert activityship.reload.receive_feedback?

    click_link 'Receiving feedback'
    assert page.has_link? 'Not receiving feedback'
    refute activityship.reload.receive_feedback?
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Who may see and decide applications, through Rack
  # ═══════════════════════════════════════════════════════════════════════════

  test "applicants, followers and others can't see applications or set their statuses, an applicant's own included" do
    create_closed_activity
    applicant = FactoryBot.create(:account)
    application = application_by(applicant)
    follower = FactoryBot.create(:account)
    @activity.activityships.create!(account: follower)
    base = "#{@activity.path}/activity_applications/#{application.id}"

    [applicant, follower, FactoryBot.create(:account), nil].each do |account|
      account ? sign_in_with_rack(account) : clear_cookies
      get "#{@activity.path}/applications"
      assert_redirected_to @activity.path
      get base
      assert_redirected_to @activity.path
      get "#{base}/set_status"
      assert_redirected_to @activity.path
      post "#{base}/set_status", status: 'Accepted'
      assert_redirected_to @activity.path
      post "#{base}/destroy"
      assert_redirected_to @activity.path
    end

    application.reload
    assert_equal 'Pending', application.status
    assert_nil application.statused_by
    assert_nil @activity.activityships.find_by(account: applicant)
  end

  test "an admin of another activity gets a 404 for this activity's application under their own activity's URL" do
    create_closed_activity
    applicant = FactoryBot.create(:account)
    application = application_by(applicant)
    other_activity = FactoryBot.create(:activity, privacy: 'closed')
    sign_in_with_rack(other_activity.account)
    base = "#{other_activity.path}/activity_applications/#{application.id}"

    get base
    assert_equal 404, last_response.status
    get "#{base}/set_status"
    assert_equal 404, last_response.status
    post "#{base}/set_status", status: 'Accepted'
    assert_equal 404, last_response.status
    post "#{base}/destroy"
    assert_equal 404, last_response.status

    assert_equal 'Pending', application.reload.status
    assert_nil @activity.activityships.find_by(account: applicant)
    assert_nil other_activity.activityships.find_by(account: applicant)
  end

  test 'an admin can set a status through Rack, and setting it again keeps one follower' do
    create_closed_activity
    applicant = FactoryBot.create(:account)
    application = application_by(applicant)
    sign_in_with_rack(@account)

    get "#{@activity.path}/activity_applications/#{application.id}/set_status"
    assert last_response.ok?
    post "#{@activity.path}/activity_applications/#{application.id}/set_status", status: 'Accepted'
    assert last_response.ok?
    post "#{@activity.path}/activity_applications/#{application.id}/set_status", status: 'Accepted'
    assert last_response.ok?
    assert_equal 1, @activity.activityships.and(account: applicant).count
  end

  test "the latest application page needs signing in, and shows only the signed-in person's own" do
    create_closed_activity
    applicant = FactoryBot.create(:account)
    application_by(applicant, answer: 'First answer')
    application_by(applicant, answer: 'Second answer').set(created_at: 1.minute.from_now)

    get "#{@activity.path}/activity_applications/latest"
    assert_redirected_to '/accounts/new'

    sign_in_with_rack(FactoryBot.create(:account))
    get "#{@activity.path}/activity_applications/latest"
    assert_equal 404, last_response.status

    sign_in_with_rack(applicant)
    get "#{@activity.path}/activity_applications/latest"
    assert last_response.ok?
    assert_includes last_response.body, 'Second answer'
    refute_includes last_response.body, 'First answer'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Following and administering, through Rack
  # ═══════════════════════════════════════════════════════════════════════════

  test 'people follow an open activity themselves, but not a closed or invitation-only one' do
    covers 'organisations/application-only-activities@7b2afe'
    create_organisation
    person = FactoryBot.create(:account)
    sign_in_with_rack(person)

    { 'open' => true, 'closed' => false, 'secret' => false }.each do |privacy, can_follow|
      activity = FactoryBot.create(:activity, organisation: @organisation, privacy: privacy)
      post "#{activity.path}/activityship", f: 'follow_and_subscribe'
      assert_redirected_to activity.path
      assert_equal can_follow, activity.activityships.find_by(account: person).present?, privacy
    end
  end

  test "a follower of a closed activity can stop its emails and leave, and an admin can't leave" do
    create_closed_activity
    follower = FactoryBot.create(:account)
    activityship = @activity.activityships.create!(account: follower)

    sign_in_with_rack(follower)
    post "#{@activity.path}/activityship", f: 'follow_without_subscribing'
    assert activityship.reload.unsubscribed?
    post "#{@activity.path}/activityship", f: 'not_following'
    assert_nil @activity.activityships.find_by(account: follower)

    sign_in_with_rack(@account)
    post "#{@activity.path}/activityship", f: 'not_following'
    assert @activity.activityships.find_by(account: @account)
  end

  test "hiding and showing membership needs signing in and following, and changes only one's own" do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'open')
    follower, other_follower = Array.new(2) { FactoryBot.create(:account) }
    activityship = activity.activityships.create!(account: follower)
    other_activityship = activity.activityships.create!(account: other_follower)

    post "#{activity.path}/hide_membership"
    assert_redirected_to '/accounts/new'

    sign_in_with_rack(FactoryBot.create(:account))
    post "#{activity.path}/hide_membership"
    assert_equal 404, last_response.status
    post "#{activity.path}/show_membership"
    assert_equal 404, last_response.status

    sign_in_with_rack(follower)
    post "#{activity.path}/hide_membership"
    assert activityship.reload.hide_membership?
    refute other_activityship.reload.hide_membership?
    post "#{activity.path}/show_membership"
    refute activityship.reload.hide_membership?
  end

  test "followers can't add followers or choose to receive feedback" do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    follower = FactoryBot.create(:account)
    activityship = activity.activityships.create!(account: follower)
    sign_in_with_rack(follower)

    assert_no_difference -> { Account.count } do
      post "#{activity.path}/add_follower", email: 'newcomer@example.com'
    end
    assert_redirected_to activity.path
    assert_equal 2, activity.activityships.count

    post "#{activity.path}/receive_feedback/1"
    assert_redirected_to activity.path
    refute activityship.reload.receive_feedback?
  end

  test "followers can't edit an activity, and admins can't set its protected fields with a forged form" do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    name = activity.name
    follower = FactoryBot.create(:account)
    activity.activityships.create!(account: follower)

    sign_in_with_rack(follower)
    get "#{activity.path}/edit"
    assert_redirected_to activity.path
    post "#{activity.path}/edit", activity: { name: 'Taken over' }
    assert_redirected_to activity.path
    assert_equal name, activity.reload.name

    sign_in_with_rack(@account)
    [{ feedback_summary: 'Forged' }, { feedback_summary_last_refreshed_at: Time.now.to_s }, { has_image: '1' }].each do |activity_params|
      error = assert_raises(RuntimeError) { post "#{activity.path}/edit", activity: activity_params.merge(name: 'Renamed') }
      assert_match(/are protected/, error.message)
    end
    activity.reload
    assert_equal name, activity.name
    assert_nil activity.feedback_summary
    assert_nil activity.feedback_summary_last_refreshed_at
  end

  test "a locked activity's page is for its admins only" do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, locked: true)

    sign_in_with_rack(FactoryBot.create(:account))
    get activity.path
    assert_redirected_to "/o/#{@organisation.slug}"

    sign_in_with_rack(@account)
    get activity.path
    assert last_response.ok?
    assert_includes last_response.body, activity.name
  end

  test 'only admins preview application questions as they edit them' do
    create_closed_activity
    path = "#{@activity.path}/application_questions"

    sign_in_with_rack(FactoryBot.create(:account))
    get path, questions: 'What will you bring?'
    assert_redirected_to @activity.path

    sign_in_with_rack(@account)
    get path, questions: 'What will you bring?', hide_location: '1'
    assert last_response.ok?
    assert_includes last_response.body, 'What will you bring?'
    refute @activity.reload.hide_location?, "The preview shouldn't save the activity"
  end
end
