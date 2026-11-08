require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# A gathering's rules, seen in the browser: what people can't do or see, and the limits on who gets in and what fills up.
# What each feature does is in gathering_features_test.rb
class GatheringRulesTest < ActiveSupport::TestCase
  include Capybara::DSL

  def create_member(name: 'Member Person', **attrs)
    FactoryBot.create(:account, name: name, **attrs).tap { |account| @gathering.memberships.create!(account: account) }
  end

  def gathering_path(path = '')
    "/g/#{@gathering.slug}#{path}"
  end

  test 'members see no admin controls, and admin pages turn them away' do
    create_gathering(privacy: 'open')
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    timetable = @gathering.timetables.create!(name: 'Workshops', account: @account)
    create_member(name: 'Other Member')
    @gathering.mapplications.create!(account: FactoryBot.create(:account, name: 'Keen Applicant'), status: 'pending')
    sign_in(create_member)

    visit gathering_path('/members')
    assert page.has_content? 'Other Member'
    assert page.has_no_link? 'Make admin'
    assert page.has_no_link? 'Remove'
    visit gathering_path("/rotas/#{rota.id}")
    assert page.has_content? 'Kitchen'
    assert page.has_no_field? placeholder: 'New role'
    assert page.has_no_link? 'Edit rota'
    visit gathering_path("/timetables/#{timetable.id}")
    assert page.has_link? 'Propose an activity'
    assert page.has_no_field? placeholder: 'New space'
    visit gathering_path('/options')
    assert page.has_link? 'Add an option'
    assert page.has_no_link? 'Add someone to an option'

    # Members see applications, to propose and support people, but only admins decide them
    visit gathering_path('/applications')
    assert page.has_content? 'Keen Applicant'
    assert page.has_link? 'Propose'
    assert page.has_no_link? 'Accept'
    assert page.has_no_link? 'Pause'

    visit gathering_path('/edit')
    assert page.has_current_path?(gathering_path, ignore_query: true)
  end

  test 'people who are not members are sent to join, to apply or away, by how private the gathering is' do
    outsider = FactoryBot.create(:account)
    sign_in(outsider)
    { 'open' => '/join', 'closed' => '/apply' }.each do |privacy, path|
      create_gathering(privacy: privacy)
      visit gathering_path
      assert page.has_current_path?(gathering_path(path), ignore_query: true), privacy
    end
    create_gathering(privacy: 'secret')
    visit gathering_path
    assert page.has_current_path?('/', ignore_query: true)
  end

  test 'an application is accepted straight away when no proposers are needed' do
    create_gathering(privacy: 'closed', fixed_threshold: 0)
    applicant = FactoryBot.create(:account)
    sign_in(applicant)
    visit gathering_path('/apply')
    click_button 'Apply'
    assert page.has_current_path?(gathering_path('/apply?accepted=true'))
    assert @gathering.memberships.find_by(account: applicant)
  end

  test 'a full gathering takes no more members, and a paused application waits' do
    create_gathering(privacy: 'closed', fixed_threshold: 0, member_limit: 1)
    applicant = FactoryBot.create(:account, name: 'Keen Applicant')
    sign_in(applicant)
    visit gathering_path('/apply')
    click_button 'Apply'
    assert page.has_current_path?(gathering_path('/apply?applied=true'))
    assert_nil @gathering.memberships.find_by(account: applicant)

    sign_in(@account)
    visit gathering_path('/applications')
    assert page.has_content? 'Keen Applicant'
    assert page.has_no_link? 'Accept'
    click_link 'Pause'
    # Moved off the applications to the paused ones
    assert page.has_content? 'Non-members can apply via'
    assert page.has_no_content? 'Keen Applicant'
    visit gathering_path('/applications/paused')
    assert page.has_content? 'Keen Applicant'
    assert page.has_link? 'Unpause'
  end

  test "a shift once taken, or marked not needed, can't be signed up for" do
    create_gathering(privacy: 'open')
    rota = @gathering.rotas.create!(name: 'Kitchen', account: @account)
    Role.create!(name: 'Cook', rota: rota)
    Rslot.create!(name: 'Morning', rota: rota)
    Rslot.create!(name: 'Evening', rota: rota)
    first = create_member(name: 'First Member')
    second = create_member(name: 'Second Member')

    sign_in(@account)
    visit gathering_path("/rotas/#{rota.id}")
    all("a[aria-label='Mark as not needed']").last.click
    assert page.has_css? "a[aria-label='Not needed: click to reopen']"

    sign_in(first)
    visit gathering_path("/rotas/#{rota.id}")
    assert page.has_css? '.visually-hidden', text: 'Not needed', visible: :all
    assert_equal 1, all("a[aria-label='Sign up']").count
    find("a[aria-label='Sign up']").click
    assert page.has_css? "img[alt='First Member']"

    sign_in(second)
    visit gathering_path("/rotas/#{rota.id}")
    assert page.has_css? "img[alt='First Member']"
    assert page.has_no_css? "a[aria-label='Sign up']"
    assert_nil rota.shifts.find_by(account: second)
  end
end
