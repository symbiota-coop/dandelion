require_relative '../test_config'

# Pausing password sign in after wrong passwords, for longer after each
class AccountPasswordSignInPausesTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'wrong passwords pause password sign in, the right one included, until the pause ends' do
    account = FactoryBot.create(:account)
    Account::FREE_FAILED_SIGN_INS.times { assert_nil Account.authenticate(account.email, 'wrong password') }
    assert_not account.reload.password_sign_in_paused?
    assert_equal account.id, Account.authenticate(account.email, account.password).id
    assert_equal 0, account.reload.failed_sign_in_attempts

    (Account::FREE_FAILED_SIGN_INS + 1).times { Account.authenticate(account.email, 'wrong password') }
    assert account.reload.password_sign_in_paused?
    assert_nil Account.authenticate(account.email, account.password)
    # A password tried while paused isn't counted
    assert_equal Account::FREE_FAILED_SIGN_INS + 1, account.reload.failed_sign_in_attempts

    travel_to(Account::FIRST_SIGN_IN_PAUSE.from_now + 1.second) do
      assert_equal account.id, Account.authenticate(account.email, account.password).id
      assert_equal 0, account.reload.failed_sign_in_attempts
      assert_nil account.password_sign_in_paused_until
    end
  end

  test 'each wrong password after the first pause doubles it, up to a day' do
    free = Account::FREE_FAILED_SIGN_INS
    assert_equal 0, Account.sign_in_pause_after(free)
    assert_equal 1.minute, Account.sign_in_pause_after(free + 1)
    assert_equal 2.minutes, Account.sign_in_pause_after(free + 2)
    assert_equal 4.minutes, Account.sign_in_pause_after(free + 3)
    assert_equal 1.day, Account.sign_in_pause_after(free + 20)
    assert_equal 1.day, Account.sign_in_pause_after(1000)

    account = FactoryBot.create(:account, failed_sign_in_attempts: free + 2)
    Account.authenticate(account.email, 'wrong password')
    assert_in_delta 4.minutes.from_now, account.reload.password_sign_in_paused_until, 5
  end

  test 'an account the old lock had stopped at 99 wrong passwords can sign in with its password again' do
    account = FactoryBot.create(:account, failed_sign_in_attempts: 99)
    assert_equal account.id, Account.authenticate(account.email, account.password).id
  end

  test 'a check that another has counted since it read the account is refused' do
    account = FactoryBot.create(:account)
    stale = Account.find(account.id)
    Account.authenticate(account.email, 'wrong password')
    Account.stub(:find_by, stale) do
      assert_nil Account.authenticate(account.email, account.password)
    end
    assert_equal 1, account.reload.failed_sign_in_attempts
  end

  test 'someone paused is told to use a sign in code, which ends the pause' do
    account = FactoryBot.create(:account, email_confirmed: true, failed_sign_in_attempts: Account::FREE_FAILED_SIGN_INS)
    visit '/accounts/sign_in'
    fill_in 'Email', with: account.email
    fill_in 'Password', with: 'wrong password'
    click_button 'Sign in'
    assert page.has_content?('You can try your password again in 1 minute')

    visit "/?sign_in_code=#{Account.find(account.id).issue_sign_in_code!}"
    assert page.has_content?('Signed in')
    assert_not account.reload.password_sign_in_paused?
    assert_equal 0, account.failed_sign_in_attempts
  end
end
