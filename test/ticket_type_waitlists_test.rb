require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class TicketTypeWaitlistsTest < ActiveSupport::TestCase
  include Capybara::DSL

  def create_ticket_type_waitlist_event(hide_unavailable_tickets: false)
    create_full_event_hierarchy(
      event_options: {
        prices: [10],
        allow_ticket_type_waitlists: true,
        hide_unavailable_tickets: hide_unavailable_tickets,
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

  test 'sold out event with ticket type waitlists shows ticket type waitlist controls' do
    create_ticket_type_waitlist_event(hide_unavailable_tickets: true)
    sell_out_ticket_type

    assert @event.sold_out?, 'Event should be sold out'
    assert @event.ticket_type_waitlists_available?, 'Ticket type waitlist controls should be available'

    visit "/e/#{@event.slug}"

    assert page.has_css?('button.join-ticket-type-waitlist', text: 'Join waitlist'),
           'Sold-out waitlistable ticket types should render join buttons'
    refute page.has_field?('waitship_name'),
           'Generic event waitlist form should not replace per-ticket waitlist controls'
  end

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
