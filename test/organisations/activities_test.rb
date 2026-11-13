require_relative '../test_config'

class ActivitiesTest < ActiveSupport::TestCase
  include Capybara::DSL

  APPLICATION_QUESTIONS = "q1\nq2\nq3".freeze

  def fill_application_answers
    question_count = APPLICATION_QUESTIONS.split("\n").length
    question_count.times do |i|
      fill_in "answers[#{i}]", with: "a#{i + 1}"
    end
  end

  def create_activity_with_questions
    create_organisation
    @activity = FactoryBot.create(:activity, organisation: @organisation, application_questions: APPLICATION_QUESTIONS)
  end

  test 'creating an activity' do
    covers_route 'GET /activities/new'
    covers_route 'POST /activities/new'
    create_organisation
    activity = FactoryBot.build_stubbed(:activity)
    sign_in(@account)
    visit "/o/#{@organisation.slug}"
    click_link 'Create an activity'
    fill_in 'Name', with: activity.name
    click_button 'Create activity'
    assert page.has_content? 'The activity was created'
  end

  test 'editing an activity' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    sign_in(@account)
    visit "#{activity.path}/edit"
    fill_in 'Name', with: (name = FactoryBot.build_stubbed(:activity).name)
    click_button 'Update activity'
    assert page.has_content? 'The activity was saved'
    assert page.has_content? name
  end

  test 'organisation_id and account_id cannot be reassigned on update' do
    activity = FactoryBot.create(:activity)
    assert_cannot_reassign_organisation_or_account(activity)
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Applications
  # ═══════════════════════════════════════════════════════════════════════════

  test 'applying to an activity when not logged in' do
    create_activity_with_questions
    applicant = FactoryBot.build_stubbed(:account)
    visit "#{@activity.path}/apply"
    fill_in 'Full name', with: applicant.name
    fill_in 'Email', with: applicant.email
    fill_application_answers
    click_button 'Apply'
    assert page.has_content? 'Thanks for applying'
  end

  test 'applying to an activity when already a member' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    sign_in(@account)
    visit "#{activity.path}/apply"
    assert page.has_content? 'Preview of application form'
  end

  test 'activity application with questions' do
    create_organisation
    questions = <<~QUESTIONS.strip
      # Application Form
      - Please fill out all fields
      Tell us about yourself
      Experience level <Beginner, Intermediate, Expert>
      Areas of interest [Design, Development, Marketing]
      [I confirm my availability]
      {Preferred start date}
    QUESTIONS
    activity = FactoryBot.create(:activity,
                                 organisation: @organisation,
                                 application_questions: questions)
    applicant = FactoryBot.create(:account)
    sign_in(applicant)
    visit "#{activity.path}/apply"

    assert page.has_content?('Application Form')
    assert page.has_content?('Please fill out all fields')

    # Fill in all question types (indices 0 and 1 are header and plain text)
    fill_in 'answers[2]', with: 'I am a motivated individual'
    select 'Intermediate', from: 'answers[3]'
    find('label[for="answers-4-0"]').click # Design
    find('label[for="answers-4-1"]').click # Development
    find('label[for="answers-5"]').click   # Single checkbox
    fill_in 'answers[6]', with: '2024-08-01'

    click_button 'Apply'
    assert page.has_content?('Thanks for applying')

    application = activity.activity_applications.last
    answers = application.answers.to_h
    q = activity.application_questions_a

    assert_equal 'I am a motivated individual', answers[q[2]]
    assert_equal 'Intermediate', answers[q[3]]
    assert_equal %w[Design Development], answers[q[4]]
    assert_equal '1', answers[q[5]]
    assert_equal '2024-08-01', answers[q[6]]
  end

  # Applies to the activity as someone not signed in
  def apply(applicant)
    visit "#{@activity.path}/apply"
    fill_in 'Full name', with: applicant.name
    fill_in 'Email', with: applicant.email
    fill_application_answers
    click_button 'Apply'
    assert page.has_content? 'Thanks for applying'
  end

  test 'organisers are emailed when people apply to an activity' do
    covers 'events/activity-application-emails-organisers@c84fd8'
    covers_route 'GET /o/:organisation_slug/a/:slug/apply'
    covers_route 'POST /o/:organisation_slug/a/:slug/apply'
    create_activity_with_questions
    Delayed::Job.delete_all
    applicant = FactoryBot.build_stubbed(:account)

    apply(applicant)
    assert_equal 1, @activity.activity_applications.count

    emails = emails_sent_by_jobs(/ActivityApplication.*send_notification/m)
    assert_equal 1, emails.length
    assert_includes emails.first.recipients, @account.email
    assert_equal @activity.admins.pluck(:email).sort, emails.first.recipients.sort
  end

  test 'accepting an application makes the applicant a follower of the activity' do
    covers 'organisations/application-only-activities@7b2afe'
    create_activity_with_questions
    apply(FactoryBot.build_stubbed(:account))
    application = @activity.activity_applications.first
    applicant = application.account
    assert_nil @activity.activityships.find_by(account: applicant)

    sign_in(@account)
    visit "#{@activity.path}/activity_applications/#{application.id}"
    # The status saves as it's chosen, and comes back saying who set it
    select 'Accepted', from: 'status'
    assert page.has_content? "by #{@account.name}"

    assert_equal 'Accepted', application.reload.status
    assert @activity.activityships.find_by(account: applicant), 'The applicant should follow the activity'
  end

  test 'admins add someone who already has an account as a follower of an activity by their email' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    person = FactoryBot.create(:account)
    sign_in(@account)
    visit "#{activity.path}/followers"
    click_link 'Add a follower'
    fill_in 'Email', with: person.email.upcase
    click_button 'Add follower'
    assert page.has_content? person.name
    assert activity.activityships.find_by(account: person)
  end

  test "the followers list's Subscribed to mailer filter leaves out those unsubscribed from the activity, the organisation or everything" do
    covers_route 'GET /o/:organisation_slug/a/:slug/followers'
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation)
    subscribed, from_activity, from_organisation, from_everything = Array.new(4) { FactoryBot.create(:account) }
    [subscribed, from_activity, from_organisation, from_everything].each do |account|
      @organisation.organisationships.create!(account: account, unsubscribed: account == from_organisation)
      activity.activityships.create!(account: account, unsubscribed: account == from_activity)
    end
    from_everything.set(unsubscribed: true)

    sign_in(@account)
    visit "#{activity.path}/followers"
    check 'Subscribed to mailer'
    assert page.has_current_path?(/subscribed_to_mailer/)
    assert page.has_content? subscribed.name
    [from_activity, from_organisation, from_everything].each { |account| assert page.has_no_content? account.name }
  end
end
