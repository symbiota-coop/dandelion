require_relative '../test_config'
require_relative '../helpers/gatherings_helpers'
require_relative '../helpers/recaptcha_helpers'

# Joining an open gathering and applying to a closed one, above all while signed out: a new email makes an account, and
# an email that already has one can't be used to add that account to the gathering
class GatheringJoiningTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods
  include GatheringsHelpers
  include RecaptchaHelpers

  test 'someone signed out joins an open gathering with a new email, and is signed in as its new account' do
    covers_route 'POST /g/:slug/join'
    create_gathering(privacy: 'open')

    visit gathering_path('/join')
    fill_in 'Full name', with: 'New Joiner'
    fill_in 'Email', with: 'new.joiner@example.com'
    click_button 'Join'
    # The gathering's own page sends anyone who isn't a signed-in member back to join
    assert page.has_current_path?(gathering_path)

    joiner = Account.find_by(email: 'new.joiner@example.com')
    assert_equal 'New Joiner', joiner.name
    assert membership_of(joiner).unsubscribed
    assert_equal 1, joiner.sign_ins.count
  end

  test 'someone signed out who types the email of an existing account is asked to sign in, and nobody is added' do
    create_gathering(privacy: 'open')
    existing = FactoryBot.create(:account)

    visit gathering_path('/join')
    fill_in 'Full name', with: 'Anyone'
    fill_in 'Email', with: existing.email
    click_button 'Join'
    assert page.has_current_path?('/accounts/sign_in', ignore_query: true)
    assert page.has_content? 'Sign in to continue'
    assert_nil membership_of(existing)
  end

  test 'joining signed out with a name no account can have makes no account and no membership' do
    create_gathering(privacy: 'open')

    visit gathering_path('/join')
    fill_in 'Full name', with: 'Visit www.example.com'
    fill_in 'Email', with: 'spam.joiner@example.com'
    click_button 'Join'
    assert page.has_content? 'Some errors prevented the account from being saved'
    assert page.has_current_path?(gathering_path('/join'), ignore_query: true)
    assert_nil Account.find_by(email: 'spam.joiner@example.com')
    assert_equal 1, @gathering.memberships.count
  end

  test 'a member sees only a preview of the joining form, with no Join button to press' do
    create_gathering(privacy: 'open')
    member = create_member
    sign_in(member)

    visit gathering_path('/join')
    assert page.has_content? 'Preview of joining form'
    assert page.has_button? 'Join', disabled: true
  end

  test 'the join route tells a member they are already part of the gathering' do
    create_gathering(privacy: 'open')
    member = create_member
    sign_in_with_rack(member)

    header 'Referer', "http://example.org#{gathering_path('/join')}"
    post gathering_path('/join')
    follow_redirect!
    assert_includes last_response.body, 'already part of that gathering'
    assert_equal 1, @gathering.memberships.and(account: member).count
  end

  test "a forged join with another account's email adds no membership for it and signs nobody in as it" do
    create_gathering(privacy: 'open')
    victim = FactoryBot.create(:account)

    # Typed differently, as the route matches emails downcased and stripped
    post gathering_path('/join'), account: { name: 'Anyone', email: " #{victim.email.upcase} " }
    assert last_response.redirect?
    assert_equal '/accounts/sign_in', URI(last_response.location).path
    assert_nil last_request.env['rack.session']['account_id']
    assert_nil membership_of(victim)
    assert_equal 0, victim.sign_ins.count
  end

  test 'a forged join with no email adds nobody' do
    create_gathering(privacy: 'open')

    header 'Referer', "http://example.org#{gathering_path('/join')}"
    post gathering_path('/join'), account: { name: 'Anyone' }
    assert_equal gathering_path('/join'), URI(last_response.location).path
    assert_equal 1, @gathering.memberships.count
  end

  test 'joining or applying signed out checks recaptcha, and makes no account when it fails' do
    create_gathering(privacy: 'open')
    closed = FactoryBot.create(:gathering, account: @account, privacy: 'closed')

    verify_calls = with_recaptcha do
      post gathering_path('/join'), account: { name: 'Bot Joiner', email: 'bot.joiner@example.com' }
      post "/g/#{closed.slug}/apply", account: { name: 'Bot Applicant', email: 'bot.applicant@example.com' }
    end
    assert_equal 2, verify_calls.length
    assert_nil Account.find_by(email: 'bot.joiner@example.com')
    assert_nil Account.find_by(email: 'bot.applicant@example.com')
    assert_equal 0, closed.mapplications.count
  end

  test 'someone signed out applies to a closed gathering with a new email, which makes its account' do
    covers_route 'POST /g/:slug/apply'
    create_gathering(privacy: 'closed')

    visit gathering_path('/apply')
    fill_in 'Full name', with: 'New Applicant'
    fill_in 'Email', with: 'new.applicant@example.com'
    click_button 'Apply'
    assert page.has_current_path?(gathering_path('/apply?applied=true'))
    assert page.has_content? 'Thanks for applying'

    applicant = Account.find_by(email: 'new.applicant@example.com')
    mapplication = @gathering.mapplications.find_by(account: applicant)
    assert_equal 'pending', mapplication.status
    # The account is theirs, so the application wasn't made for someone else's
    refute mapplication.submitted_signed_out
    assert_nil membership_of(applicant)
  end

  test 'applying signed out with a name no account can have makes no account and no application' do
    create_gathering(privacy: 'closed')

    visit gathering_path('/apply')
    fill_in 'Full name', with: 'Visit www.example.com'
    fill_in 'Email', with: 'spam.applicant@example.com'
    click_button 'Apply'
    assert page.has_content? 'Some errors prevented the account from being saved'
    assert_nil Account.find_by(email: 'spam.applicant@example.com')
    assert_equal 0, @gathering.mapplications.count
  end

  test "someone signed out who types an applicant's or a member's email is told so, and no application is made" do
    create_gathering(privacy: 'closed')
    applicant = FactoryBot.create(:account)
    @gathering.mapplications.create!(account: applicant, status: 'pending')
    member = create_member

    visit gathering_path('/apply')
    fill_in 'Full name', with: 'Anyone'
    fill_in 'Email', with: applicant.email
    click_button 'Apply'
    assert page.has_content? "You've already applied to that gathering"
    assert_equal 1, @gathering.mapplications.and(account: applicant).count

    visit gathering_path('/apply')
    fill_in 'Full name', with: 'Anyone'
    fill_in 'Email', with: member.email
    click_button 'Apply'
    assert page.has_content? "You're already part of that gathering"
    assert_nil @gathering.mapplications.find_by(account: member)
  end

  test 'applicants and members signed in are offered no application form to send' do
    create_gathering(privacy: 'closed')
    applicant = FactoryBot.create(:account)
    @gathering.mapplications.create!(account: applicant, status: 'pending')

    sign_in(applicant)
    visit gathering_path('/apply')
    assert page.has_content? 'Thanks for applying'
    assert page.has_no_button? 'Apply'

    sign_in(create_member)
    visit gathering_path('/apply')
    assert page.has_content? 'Preview of application form'
    assert page.has_button? 'Apply', disabled: true
  end

  test 'the apply route makes no second application for an applicant, nor one for a member' do
    create_gathering(privacy: 'closed')
    applicant = FactoryBot.create(:account)
    @gathering.mapplications.create!(account: applicant, status: 'pending')
    member = create_member
    header 'Referer', "http://example.org#{gathering_path('/apply')}"

    sign_in_with_rack(applicant)
    post gathering_path('/apply')
    follow_redirect!
    assert_includes last_response.body, 'already applied to that gathering'
    assert_equal 1, @gathering.mapplications.and(account: applicant).count

    sign_in_with_rack(member)
    post gathering_path('/apply')
    follow_redirect!
    assert_includes last_response.body, 'already part of that gathering'
    assert_nil @gathering.mapplications.find_by(account: member)
  end
end
