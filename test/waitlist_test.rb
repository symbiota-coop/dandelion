require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class WaitlistTest < ActiveSupport::TestCase
  include Capybara::DSL

  def create_ticket_type_waitlist_event
    create_full_event_hierarchy(
      event_options: {
        prices: [10],
        allow_ticket_type_waitlists: true,
        suggested_donation: 0
      }
    )
    @ticket_type = @event.ticket_types.first
  end

  def sell_out_ticket_type
    @ticket_type.set(quantity: 0)
    @event.refresh_sold_out_cache_and_notify_waitlist
    @event.reload
  end

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
    buyer = FactoryBot.create(:account)

    # Create waitship directly to test the after_create callback
    @event.waitships.create(account: buyer)

    # Verify subscriptions were created
    assert @organisation.organisationships.find_by(account: buyer),
           'Should create organisationship'
    assert @activity.activityships.find_by(account: buyer),
           'Should create activityship for open activity'
    assert @local_group.local_groupships.find_by(account: buyer),
           'Should create local_groupship'
  end

  test 'waitship removed when ticket payment completed' do
    create_event(prices: [10])
    buyer = FactoryBot.create(:account)

    # Add user to waitlist (bypass callbacks by using save without validation)
    waitship = Waitship.new(account: buyer, event: @event)
    waitship.save(validate: false)
    assert @event.waitships.find_by(account: buyer), 'Waitship should exist initially'

    # Create a ticket directly
    ticket_type = @event.ticket_types.first
    ticket = Ticket.create!(
      event: @event,
      account: buyer,
      ticket_type: ticket_type,
      price: 10
    )

    # Call payment_completed! on the ticket
    ticket.payment_completed!

    # Waitship should be removed
    assert_nil @event.reload.waitships.find_by(account: buyer),
               'Waitship should be removed after ticket payment completed'
  end

  test 'cannot join waitlist twice' do
    create_event(prices: [10])
    buyer = FactoryBot.create(:account)

    # Create first waitship
    waitship1 = Waitship.create!(account: buyer, event: @event)
    assert waitship1.persisted?, 'First waitship should be created'

    # Try to create duplicate via model
    waitship2 = Waitship.new(account: buyer, event: @event)
    assert_not waitship2.valid?, "Duplicate waitship should not be valid. Errors: #{waitship2.errors.full_messages}"
    # Mongoid puts uniqueness errors on the field name (account_id)
    assert waitship2.errors[:account_id].present? || waitship2.errors[:account].present?,
           "Should have uniqueness error. All errors: #{waitship2.errors.full_messages}"
  end

  test 'waitlist with activity having non-open privacy does not create activityship' do
    create_organisation
    activity = FactoryBot.create(:activity, organisation: @organisation, privacy: 'secret')
    create_event(activity: activity, prices: [10])
    buyer = FactoryBot.create(:account)
    @event.waitships.create(account: buyer)

    # Should NOT create activityship for non-open activity
    assert_nil activity.activityships.find_by(account: buyer),
               'Should not create activityship for secret activity'

    # Should still create organisationship
    assert @organisation.organisationships.find_by(account: buyer),
           'Should still create organisationship'
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Ticket type waitlists
  # ═══════════════════════════════════════════════════════════════════════════

  test 'joining ticket type waitlist creates waitship for selected ticket type' do
    create_ticket_type_waitlist_event
    sell_out_ticket_type

    visit "/e/#{@event.slug}"
    find('button.join-ticket-type-waitlist').click

    account = FactoryBot.build_stubbed(:account)

    fill_in 'ticket-type-waitlist-name', with: account.name
    fill_in 'ticket-type-waitlist-email', with: account.email
    execute_script "window.grecaptcha = { getResponse: function() { return 'test-token'; }, reset: function() {} }"
    within '#ticket-type-waitlist-modal' do
      click_button 'Join waitlist'
    end

    assert page.has_content?('Joined waitlist!'), 'Successful join should update the ticket type row'
    waitlist_account = Account.find_by(email: account.email)
    assert waitlist_account.present?, 'Account should be created'
    assert @ticket_type.ticket_type_waitships.find_by(account: waitlist_account),
           'Ticket type waitship should be created for the selected ticket type'
    assert_nil @event.waitships.find_by(account: waitlist_account),
               'Joining a ticket type waitlist should not create an event waitship'
  end

  test 'sales ended ticket type uses generic sold out flow instead of ticket type waitlist controls' do
    create_ticket_type_waitlist_event
    @ticket_type.set(quantity: 0, sales_end: 1.hour.ago)
    @event.refresh_sold_out_cache_and_notify_waitlist
    @event.reload

    refute @event.ticket_type_waitlists_available?,
           'Ticket type waitlists should not be available once sales have ended'

    visit "/e/#{@event.slug}"

    assert page.has_content?('Sales have ended for this event')
    refute page.has_css?('button.join-ticket-type-waitlist'),
           'Sales-ended ticket types should not render per-ticket waitlist buttons'
  end

  test 'ticket type waitship is removed when matching ticket payment completes' do
    create_ticket_type_waitlist_event
    sell_out_ticket_type
    account = FactoryBot.create(:account)

    TicketTypeWaitship.create!(ticket_type: @ticket_type, account: account)
    assert @ticket_type.ticket_type_waitships.find_by(account: account),
           'Ticket type waitship should exist before purchase'

    @ticket_type.set(quantity: 1)
    ticket = Ticket.create!(
      event: @event,
      account: account,
      ticket_type: @ticket_type,
      price: @ticket_type.price
    )
    ticket.payment_completed!

    assert_nil @ticket_type.reload.ticket_type_waitships.find_by(account: account),
               'Ticket type waitship should be removed after purchase'
  end

  test 'ticket type waitlist notification triggered when tickets become available' do
    Delayed::Job.delete_all if defined?(Delayed::Job)
    create_ticket_type_waitlist_event
    sell_out_ticket_type
    account = FactoryBot.create(:account)

    TicketTypeWaitship.create!(ticket_type: @ticket_type, account: account)
    assert @ticket_type.reload.sold_out?, 'Ticket type should be sold out'
    assert @ticket_type.sold_out_cache?, 'Ticket type sold-out cache should be primed'

    @ticket_type.set(quantity: 1)
    @event.refresh_sold_out_cache_and_notify_waitlist

    assert_not @ticket_type.reload.sold_out?, 'Ticket type should no longer be sold out'
    assert_equal 1, Delayed::Job.and(handler: /send_ticket_type_waitlist_tickets_available/).count,
                 'Ticket type waitlist notification should be queued'
  end
end

