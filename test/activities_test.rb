require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class ActivitiesTest < ActiveSupport::TestCase
  include Capybara::DSL

  APPLICATION_QUESTIONS = "q1\nq2\nq3"

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
    visit "/activities/#{activity.id}/edit"
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
    visit "/activities/#{@activity.id}/apply"
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
    visit "/activities/#{activity.id}/apply"
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
    visit "/activities/#{activity.id}/apply"

    # Verify header and plain text are displayed
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
end

