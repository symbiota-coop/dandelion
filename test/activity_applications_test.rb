require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DandelionTest < ActiveSupport::TestCase
  include Capybara::DSL

  APPLICATION_QUESTIONS = "q1\nq2\nq3"

  def fill_application_answers
    question_count = APPLICATION_QUESTIONS.split("\n").length
    question_count.times do |i|
      fill_in "answers[#{i}]", with: "a#{i + 1}"
    end
  end

  test 'applying to an activity when not logged in' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @activity = FactoryBot.create(:activity, organisation: @organisation, account: @account, application_questions: APPLICATION_QUESTIONS)
    @applicant = FactoryBot.build_stubbed(:account)
    visit "/activities/#{@activity.id}/apply"
    fill_in 'Full name', with: @applicant.name
    fill_in 'Email', with: @applicant.email
    fill_application_answers
    click_button 'Apply'
    assert page.has_content? 'Thanks for applying'
  end

  test 'applying to an activity when logged in' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @activity = FactoryBot.create(:activity, organisation: @organisation, account: @account, application_questions: APPLICATION_QUESTIONS)
    @applicant = FactoryBot.create(:account)
    login_as(@applicant)
    visit "/activities/#{@activity.id}/apply"
    fill_application_answers
    click_button 'Apply'
    assert page.has_content? 'Thanks for applying'
  end

  test 'applying to an activity when already a member' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @activity = FactoryBot.create(:activity, organisation: @organisation, account: @account)
    FactoryBot.create(:activityship, activity: @activity, account: @account)
    login_as(@account)
    visit "/activities/#{@activity.id}/apply"
    assert page.has_content? 'Preview of application form'
  end
end
