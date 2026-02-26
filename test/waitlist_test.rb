require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class WaitlistTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'joining waitlist on sold-out event' do
    create_full_event_hierarchy(event_options: { prices: [10] })
    # Sell out the event by setting quantity to 0
    @event.ticket_types.first.set(quantity: 0)
    @event.refresh_sold_out_cache_and_notify_waitlist

    visit "/e/#{@event.slug}"
    assert page.has_content?('This event is sold out'), 'Should show sold out message'
    assert page.has_content?('Join the waitlist'), 'Should show waitlist option'

    # Fill in waitlist form
    fill_in 'waitship_name', with: 'Waitlist User'
    fill_in 'waitship_email', with: 'waitlist@example.com'

    # Mock recaptcha for testing
    execute_script "window.grecaptcha = { getResponse: function() { return 'test-token'; } }"

    click_button 'Submit'

    # Should redirect with success message
    assert current_url.include?('added_to_waitlist=true'), 'Should redirect with waitlist confirmation'

    # Verify waitship was created
    waitlist_account = Account.find_by(email: 'waitlist@example.com')
    assert waitlist_account.present?, 'Account should be created'
    assert @event.waitships.find_by(account: waitlist_account), 'Waitship should exist'
  end

  test 'waitlist creates organisationship, activityship, and local_groupship' do
    create_full_event_hierarchy(event_options: { prices: [10] })
    @account = FactoryBot.create(:account)

    # Create waitship directly to test the after_create callback
    @event.waitships.create(account: @account)

    # Verify subscriptions were created
    assert @organisation.organisationships.find_by(account: @account),
           'Should create organisationship'
    assert @activity.activityships.find_by(account: @account),
           'Should create activityship for open activity'
    assert @local_group.local_groupships.find_by(account: @account),
           'Should create local_groupship'
  end

  test 'waitship removed when ticket payment completed' do
    @org_account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @org_account)
    @event = FactoryBot.create(:event,
                               organisation: @organisation,
                               account: @org_account,
                               last_saved_by: @org_account,
                               prices: [10])
    @account = FactoryBot.create(:account)

    # Add user to waitlist (bypass callbacks by using save without validation)
    waitship = Waitship.new(account: @account, event: @event)
    waitship.save(validate: false)
    assert @event.waitships.find_by(account: @account), 'Waitship should exist initially'

    # Create a ticket directly
    ticket_type = @event.ticket_types.first
    ticket = Ticket.create!(
      event: @event,
      account: @account,
      ticket_type: ticket_type,
      price: 10
    )

    # Call payment_completed! on the ticket
    ticket.payment_completed!

    # Waitship should be removed
    assert_nil @event.reload.waitships.find_by(account: @account),
               'Waitship should be removed after ticket payment completed'
  end

  test 'cannot join waitlist twice' do
    @org_account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @org_account)
    @event = FactoryBot.create(:event,
                               organisation: @organisation,
                               account: @org_account,
                               last_saved_by: @org_account,
                               prices: [10])

    @account = FactoryBot.create(:account)

    # Create first waitship
    waitship1 = Waitship.create!(account: @account, event: @event)
    assert waitship1.persisted?, 'First waitship should be created'

    # Try to create duplicate via model
    waitship2 = Waitship.new(account: @account, event: @event)
    assert_not waitship2.valid?, "Duplicate waitship should not be valid. Errors: #{waitship2.errors.full_messages}"
    # Mongoid puts uniqueness errors on the field name (account_id)
    assert waitship2.errors[:account_id].present? || waitship2.errors[:account].present?,
           "Should have uniqueness error. All errors: #{waitship2.errors.full_messages}"
  end

  test 'waitlist notification triggered when tickets become available' do
    create_full_event_hierarchy(event_options: { prices: [10] })
    @account = FactoryBot.create(:account)

    # Add to waitlist
    @event.waitships.create(account: @account)

    # Sell out the event
    @event.ticket_types.first.set(quantity: 0)
    @event.refresh_sold_out_cache_and_notify_waitlist
    assert @event.sold_out?, 'Event should be sold out'

    # Make tickets available again - this should trigger notification
    @event.ticket_types.first.set(quantity: 10)

    # We can't easily test the email sending, but we can verify the method runs
    # The notification is handled asynchronously so we just verify the state change
    @event.refresh_sold_out_cache_and_notify_waitlist
    assert_not @event.sold_out?, 'Event should no longer be sold out'
  end

  test 'waitlist with activity having non-open privacy does not create activityship' do
    @org_account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @org_account)
    @activity = FactoryBot.create(:activity, organisation: @organisation, account: @org_account, privacy: 'secret')
    @event = FactoryBot.create(:event,
                               organisation: @organisation,
                               activity: @activity,
                               account: @org_account,
                               last_saved_by: @org_account,
                               prices: [10])

    @account = FactoryBot.create(:account)
    @event.waitships.create(account: @account)

    # Should NOT create activityship for non-open activity
    assert_nil @activity.activityships.find_by(account: @account),
               'Should not create activityship for secret activity'

    # Should still create organisationship
    assert @organisation.organisationships.find_by(account: @account),
           'Should still create organisationship'
  end
end
