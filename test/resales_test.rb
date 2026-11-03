require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class ResalesTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  test 'remaining excludes tickets made available again' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 2)
    ticket_type.tickets.create!(event: @event, payment_completed: true)
    ticket_type.tickets.create!(event: @event, payment_completed: true, made_available_at: Time.now)

    assert_equal 1, ticket_type.remaining
    assert_equal 0, ticket_type.remaining_including_made_available
  end

  test 'a ticket can be put on resale only when the event allows resales' do
    create_event(prices: [0])
    account = FactoryBot.create(:account)
    ticket = @event.ticket_types.first.tickets.create!(event: @event, account: account, payment_completed: true, price: 0)
    sign_in_with_rack(account)

    post "/tickets/#{ticket.id}/toggle_resale"
    assert_equal 403, last_response.status
    assert_nil ticket.reload.made_available_at

    @event.set(enable_resales: true)
    post "/tickets/#{ticket.id}/toggle_resale"
    assert ticket.reload.made_available_at

    # Resales turned off later: the ticket can still come off resale, back into the counts
    @event.set(enable_resales: false)
    post "/tickets/#{ticket.id}/toggle_resale"
    assert_nil ticket.reload.made_available_at
  end

  test 'turning resales off takes tickets off resale' do
    create_event(prices: [0], enable_resales: true)
    ticket_type = @event.ticket_types.first
    ticket = ticket_type.tickets.create!(event: @event, payment_completed: true, price: 0, made_available_at: Time.now)
    assert_equal 0, Event.find(@event.id).ticket_counts[ticket_type.id]

    @event.update!(enable_resales: false)
    assert_nil ticket.reload.made_available_at
    assert_equal 1, Event.find(@event.id).ticket_counts[ticket_type.id]
  end

  test "turning resales off leaves on resale a ticket whose place is held, until it's paid for" do
    create_event(prices: [0], enable_resales: true)
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 1)
    original = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: Time.now)
    # Holds the place, unpaid
    replacement = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 10)
    refute replacement.payment_completed

    @event.update!(enable_resales: false)
    assert original.reload.made_available_at
    assert_equal 1, Event.find(@event.id).ticket_counts[ticket_type.id]

    replacement.stub :send_resale_notification_to_previous_ticketholder, nil do
      replacement.stub :send_resale_notification_to_organiser, nil do
        replacement.payment_completed!
      end
    end
    assert original.reload.deleted?
    assert_equal 1, Event.find(@event.id).ticket_counts[ticket_type.id]
  end

  test "turning resales off puts back a ticket whose hold is let go" do
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 1)
    ticket_type = @event.ticket_types.first
    original = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: Time.now)
    replacement = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 10)
    refute replacement.payment_completed

    @event.update!(enable_resales: false)
    assert original.reload.made_available_at

    replacement.destroy
    assert_nil original.reload.made_available_at
    assert_equal 1, Event.find(@event.id).ticket_counts[ticket_type.id]
  end

  test 'a sale past the event capacity replaces a ticket on resale' do
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 1)
    ticket_type = @event.ticket_types.first
    original = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: Time.now)
    replacement = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 0)

    replacement.stub :send_resale_notification_to_previous_ticketholder, nil do
      replacement.stub :send_resale_notification_to_organiser, nil do
        replacement.payment_completed!
      end
    end
    assert original.reload.deleted?
  end

  test 'a sale of another ticket type past the event capacity replaces a ticket on resale' do
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 1)
    standard = @event.ticket_types.first
    concession = @event.ticket_types.create!(name: 'Concession', price: 0, quantity: 10)
    original = standard.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: Time.now)
    replacement = concession.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 0)

    replacement.stub :send_resale_notification_to_previous_ticketholder, nil do
      replacement.stub :send_resale_notification_to_organiser, nil do
        replacement.payment_completed!
      end
    end
    assert original.reload.deleted?
  end

  test 'a sale past a ticket group capacity replaces a ticket on resale in the group' do
    create_event(prices: [0], enable_resales: true)
    standard = @event.ticket_types.first
    concession = @event.ticket_types.create!(name: 'Concession', price: 0, quantity: 10)
    outside = @event.ticket_types.create!(name: 'Outside', price: 0, quantity: 10)
    ticket_group = @event.ticket_groups.create!(name: 'Dance', capacity: 1)
    standard.update_attributes!(ticket_group: ticket_group)
    concession.update_attributes!(ticket_group: ticket_group)
    # Older, but not in the group
    elsewhere = outside.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: 1.minute.ago)
    original = standard.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: Time.now)
    replacement = concession.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 0)

    replacement.stub :send_resale_notification_to_previous_ticketholder, nil do
      replacement.stub :send_resale_notification_to_organiser, nil do
        replacement.payment_completed!
      end
    end
    assert original.reload.deleted?
    refute elsewhere.reload.deleted?
  end

  test "a ticket can't come off resale while its place is held" do
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 1)
    ticket_type = @event.ticket_types.first
    account = FactoryBot.create(:account)
    original = ticket_type.tickets.create!(event: @event, account: account, payment_completed: true, price: 0, made_available_at: Time.now)
    # Holds the place, unpaid
    hold = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 10)
    refute hold.payment_completed
    sign_in_with_rack(account)

    post "/tickets/#{original.id}/toggle_resale"
    assert original.reload.made_available_at
    assert_equal 1, Event.find(@event.id).ticket_counts[ticket_type.id]

    hold.destroy
    post "/tickets/#{original.id}/toggle_resale"
    assert_nil original.reload.made_available_at
  end

  test 'buying a zero-slot add-on at a full event leaves a ticket on resale alone' do
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 1)
    admission = @event.ticket_types.first
    add_on = @event.ticket_types.create!(name: 'Add-on', price: 0, quantity: 10, slots: 0)
    original = admission.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: Time.now)
    # Holds the place, unpaid
    replacement = admission.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 10)
    refute replacement.payment_completed
    extra = add_on.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 0)

    extra.stub :send_resale_notification_to_previous_ticketholder, nil do
      extra.stub :send_resale_notification_to_organiser, nil do
        extra.payment_completed!
      end
    end
    refute original.reload.deleted?

    replacement.stub :send_resale_notification_to_previous_ticketholder, nil do
      replacement.stub :send_resale_notification_to_organiser, nil do
        replacement.payment_completed!
      end
    end
    assert original.reload.deleted?
  end

  test 'stripe tickets do not require a manual refund' do
    create_event(prices: [30], enable_resales: true)
    ticket_type = @event.ticket_types.first
    ticket = ticket_type.tickets.create!(
      event: @event,
      account: FactoryBot.create(:account),
      payment_completed: true,
      price: 30,
      payment_intent: 'pi_123'
    )

    refute ticket.requires_manual_refund?
  end

  test 'reselling an instalment ticket tells organisers a refund is required' do
    create_event(prices: [30], enable_resales: true)
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 1)
    original = ticket_type.tickets.create!(
      event: @event,
      account: FactoryBot.create(:account),
      payment_completed: true,
      price: 30,
      gocardless_billing_request_id: 'BRQ123',
      made_available_at: Time.now
    )
    new_ticket = ticket_type.tickets.create!(
      event: @event,
      account: FactoryBot.create(:account),
      payment_completed: false,
      price: 30
    )

    previous_captured = nil
    organiser_captured = nil
    new_ticket.stub :send_resale_notification_to_previous_ticketholder, proc { |previous_account, **kwargs| previous_captured = [previous_account, kwargs] } do
      new_ticket.stub :send_resale_notification_to_organiser, proc { |previous_account, **kwargs| organiser_captured = [previous_account, kwargs] } do
        new_ticket.payment_completed!
      end
    end

    assert original.reload.deleted?
    assert_equal original.account, previous_captured[0]
    assert previous_captured[1][:requires_manual_refund]
    assert previous_captured[1][:gocardless_instalment]
    assert_equal original.account, organiser_captured[0]
    assert organiser_captured[1][:requires_manual_refund]
    assert organiser_captured[1][:gocardless_instalment]
    assert_equal 30, organiser_captured[1][:refund_amount]
    assert_equal 'GBP', organiser_captured[1][:currency]
  end

  test 'resale email mentions a GoCardless instalment refund' do
    create_event(prices: [30], enable_resales: true)
    previous_account = FactoryBot.create(:account)
    html = EmailHelper.html(
      :ticket_resale,
      account: FactoryBot.create(:account),
      event: @event,
      previous_account: previous_account,
      requires_manual_refund: true,
      gocardless_instalment: true,
      refund_amount: 30.0,
      currency: 'GBP'
    )

    assert_includes html, 'could not refund this ticket automatically (£30).'
    assert_includes html, 'GoCardless instalments'
  end

  test 'previous ticketholder resale email does not promise an automatic refund for instalments' do
    create_event(prices: [30], enable_resales: true)
    html = EmailHelper.html(
      :ticket_resale_previous_ticketholder,
      event: @event,
      requires_manual_refund: true,
      gocardless_instalment: true
    )

    refute_includes html, 'refund shortly'
    assert_includes html, 'organiser has been notified and will process your refund'
    assert_includes html, 'GoCardless instalments'
  end

  test 'previous ticketholder resale email does not promise an automatic refund when a manual refund is required' do
    create_event(prices: [30], enable_resales: true)
    html = EmailHelper.html(
      :ticket_resale_previous_ticketholder,
      event: @event,
      requires_manual_refund: true,
      gocardless_instalment: false
    )

    refute_includes html, 'refund shortly'
    assert_includes html, 'organiser has been notified and will process your refund'
    refute_includes html, 'GoCardless instalments'
  end

  test 'previous ticketholder resale email promises a refund when one can be issued automatically' do
    create_event(prices: [30], enable_resales: true)
    html = EmailHelper.html(
      :ticket_resale_previous_ticketholder,
      event: @event,
      requires_manual_refund: false
    )

    assert_includes html, 'You should receive a refund shortly.'
    refute_includes html, 'organiser has been notified'
  end
end
