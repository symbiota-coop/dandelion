require_relative '../test_config'

# What the profile form refuses: usernames that look like account ids, links in a new account's bio, names with links,
# $ or @ in them, and dates of birth that aren't in the past
class AccountProfileValidationTest < ActiveSupport::TestCase
  include Capybara::DSL

  def edit_profile(account)
    sign_in(account)
    visit '/accounts/edit'
  end

  def save_profile
    click_button 'Save profile'
  end

  def assert_profile_refused(message)
    assert page.has_content?('Some errors prevented the account from being saved')
    assert page.has_content?(message)
  end

  def assert_profile_saved
    assert page.has_content?('Your account was updated successfully')
  end

  def fill_in_bio(html)
    assert page.has_css?('.ck-editor')
    execute_script "document.getElementById('account_bio').ckeditorInstance.setData(#{html.to_json})"
  end

  test "a username can't be changed to one that looks like an account id, which URLs would take for another account" do
    account = FactoryBot.create(:account)
    username = account.username
    edit_profile(account)

    fill_in 'Username', with: BSON::ObjectId.new.to_s
    save_profile
    assert_profile_refused "can't look like an account id"
    assert_equal username, account.reload.username

    fill_in 'Username', with: 'pat_reid.2'
    save_profile
    assert_profile_saved
    assert_equal 'pat_reid.2', account.reload.username
  end

  test 'an account whose username already looks like an id can still save other changes' do
    account = FactoryBot.create(:account)
    account.set(username: (username = BSON::ObjectId.new.to_s))
    account.reload.name = 'Pat Reid'
    assert account.save
    assert_equal username, account.reload.username
  end

  test "a bio can't have links until the account has done something on Dandelion, as an anti-spam measure" do
    account = FactoryBot.create(:account)
    refute account.live_player?
    edit_profile(account)

    fill_in_bio '<p>See <a href="https://example.com">my site</a></p>'
    save_profile
    assert_profile_refused 'cannot contain links yet as an anti-spam measure'
    assert_nil account.reload.bio

    fill_in_bio '<p>I like walks</p>'
    save_profile
    assert_profile_saved
    assert_equal '<p>I like walks</p>', account.reload.bio

    organisation = FactoryBot.create(:organisation)
    organisation.organisationships.create!(account: account)
    assert account.live_player?
    visit '/accounts/edit'
    fill_in_bio '<p>See <a href="https://example.com">my site</a></p>'
    save_profile
    assert_profile_saved
    assert_includes account.reload.bio, 'https://example.com'
  end

  test "a name can't contain $, @, www. or a link, nor their full-width lookalikes" do
    account = FactoryBot.create(:account, name: 'Pat Reid')
    edit_profile(account)

    { 'Pat $ Reid' => 'must not contain $',
      'Pat ＄ Reid' => 'must not contain $',
      'Pat＠example.com' => 'must not contain @',
      'Pat www.example.com' => 'must not contain www.',
      'Pat http://example.com' => 'must not contain http://',
      'Pat https://example.com' => 'must not contain https://',
      'Pat ｈｔｔｐｓ：／／example.com' => 'must not contain https://' }.each do |name, message|
      fill_in 'Full name', with: name
      save_profile
      assert_profile_refused message
      assert_equal 'Pat Reid', account.reload.name, name
    end

    # An email address is cut at the @
    fill_in 'Full name', with: 'Sam@example.com'
    save_profile
    assert_profile_saved
    assert_equal 'Sam', account.reload.name

    visit '/accounts/edit'
    fill_in 'Full name', with: 'Sam Rivers'
    save_profile
    assert_profile_saved
    assert_equal 'Sam Rivers', account.reload.name
  end

  test "a date of birth must make the account's age positive" do
    account = FactoryBot.create(:account)
    edit_profile(account)

    [Date.tomorrow, Date.today].each do |date|
      execute_script "document.getElementById('account_date_of_birth')._flatpickr.setDate(#{date.iso8601.to_json})"
      save_profile
      assert_profile_refused 'Date of birth is invalid'
      assert_nil account.reload.date_of_birth, date
    end

    execute_script "document.getElementById('account_date_of_birth')._flatpickr.setDate('1990-06-15')"
    save_profile
    assert_profile_saved
    assert_equal Date.new(1990, 6, 15), account.reload.date_of_birth.to_date
  end
end
