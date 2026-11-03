require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class ResalesTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  # Stands in for Mailgun::BatchMessage, keeping who an email would go to
  class RecordedEmail
    attr_reader :recipients

    def initialize
      @recipients = []
    end

    def add_recipient(_type, email, _variables)
      @recipients << email
    end

    def from(*); end
    def subject(*); end
    def body_html(*); end
    def reply_to(*); end
    def finalize; end
  end

  def recorded_email
    email = RecordedEmail.new
    Mailgun::BatchMessage.stub :new, email do
      yield
    end
    email
  end

  def complete_without_notifications(ticket)
    ticket.stub :send_resale_notification_to_previous_ticketholder, nil do
      ticket.stub :send_resale_notification_to_organiser, nil do
        ticket.payment_completed!
      end
    end
  end

  test 'remaining excludes tickets made available again' do
    covers 'events/resale-frees-place@9c6500'
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 2)
    ticket_type.tickets.create!(event: @event, payment_completed: true)
    ticket_type.tickets.create!(event: @event, payment_completed: true, made_available_at: Time.now)

    assert_equal 1, ticket_type.remaining
    assert_equal 0, ticket_type.remaining_including_made_available
  end

  test 'a ticket can be put on resale only when the event allows resales' do
    covers 'events/resales-are-enabled-per-event@54eb5b', 'events/resale-at-any-time@182662', 'events/resale-can-be-removed@7f031e'
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
    covers 'events/resale-frees-place@9c6500', 'events/resales-off-returns-tickets@ad509e'
    create_event(prices: [0], enable_resales: true)
    ticket_type = @event.ticket_types.first
    ticket = ticket_type.tickets.create!(event: @event, payment_completed: true, price: 0, made_available_at: Time.now)
    assert_equal 0, Event.find(@event.id).ticket_counts[ticket_type.id]

    @event.update!(enable_resales: false)
    assert_nil ticket.reload.made_available_at
    assert_equal 1, Event.find(@event.id).ticket_counts[ticket_type.id]
  end

  test "turning resales off leaves on resale a ticket whose place is held, until it's paid for" do
    covers 'events/resales-off-while-held@71db3d', 'events/resold-past-limit@0b575f'
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
    covers 'events/resales-off-while-held@71db3d'
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
    covers 'events/resold-past-limit@0b575f'
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
    covers 'events/resale-any-ticket-type@206f1d'
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
    covers 'events/resold-past-limit@0b575f', 'events/resale-frees-place@9c6500'
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
    covers 'events/resale-held-for-buyer@9f6b27'
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
    covers 'events/resold-past-limit@0b575f'
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
    covers 'events/resale-instalments-refunded-by-hand@b16ce9', 'events/resale-emails-ticketholder@659bbc'
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
    covers 'events/resale-instalments-refunded-by-hand@b16ce9'
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
    covers 'events/resale-instalments-refunded-by-hand@b16ce9'
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
    covers 'events/resale-emails-ticketholder@659bbc'
    create_event(prices: [30], enable_resales: true)
    html = EmailHelper.html(
      :ticket_resale_previous_ticketholder,
      event: @event,
      requires_manual_refund: false
    )

    assert_includes html, 'You should receive a refund shortly.'
    refute_includes html, 'organiser has been notified'
  end

  test 'the ticket on resale longest is resold first' do
    covers 'events/resale-oldest-first@a644b1'
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 2)
    ticket_type = @event.ticket_types.first
    newer = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: 1.minute.ago)
    older = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: 2.minutes.ago)
    replacement = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 10)

    complete_without_notifications(replacement)
    assert older.reload.deleted?
    refute newer.reload.deleted?
  end

  test 'a sale of a ticket taking two places resells two tickets on resale taking one' do
    covers 'events/resale-of-several-places@162449'
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 2)
    single = @event.ticket_types.first
    pair = @event.ticket_types.create!(name: 'Pair', price: 0, quantity: 10, slots: 2)
    older = single.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: 2.minutes.ago)
    newer = single.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: 1.minute.ago)
    replacement = pair.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 0)

    complete_without_notifications(replacement)
    assert older.reload.deleted?
    assert newer.reload.deleted?
  end

  test 'payments completing at once resell different tickets on resale' do
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 2)
    ticket_type = @event.ticket_types.first
    older = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: 2.minutes.ago)
    newer = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: 1.minute.ago)
    first = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 0)
    second = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 0)
    # What the second payment found before the first resold it
    stale = Ticket.find(older.id)

    complete_without_notifications(first)
    assert older.reload.deleted?

    found = [stale]
    resold_again = false
    stale.stub :refund, -> { resold_again = true } do
      second.stub :ticket_on_resale_replaced, -> { found.shift || Ticket.instance_method(:ticket_on_resale_replaced).bind_call(second) } do
        complete_without_notifications(second)
      end
    end
    refute resold_again
    assert newer.reload.deleted?
  end

  test "an error reselling a ticket doesn't stop the sale completing" do
    covers 'events/resale-refund-fails@856deb'
    create_event(prices: [15], enable_resales: true)
    @event.set(capacity: 1)
    ticket_type = @event.ticket_types.first
    account = FactoryBot.create(:account)
    order = Order.create!(event: @event, account: account, value: 15, payment_completed: true, payment_intent: 'pi_resold', currency: 'GBP')
    original = ticket_type.tickets.create!(event: @event, order: order, account: account, payment_completed: true, price: 15, payment_intent: 'pi_resold', made_available_at: Time.now)
    buyer = FactoryBot.create(:account)
    Waitship.create!(event: @event, account: buyer)
    replacement = ticket_type.tickets.create!(event: @event, account: buyer, payment_completed: false, price: 15)

    reported = []
    organiser_email = nil
    ErrorReporting.stub(:capture_exception, ->(e, **) { reported << e }) do
      Stripe::PaymentIntent.stub :retrieve, proc { raise Stripe::APIConnectionError, 'Stripe is down' } do
        replacement.stub :send_resale_notification_to_previous_ticketholder, proc { raise Mailgun::CommunicationError, 'Mailgun is down' } do
          replacement.stub :send_resale_notification_to_organiser, proc { |_account, **kwargs| organiser_email = kwargs } do
            replacement.payment_completed!
          end
        end
      end
    end
    assert original.reload.deleted?
    # Left for the organisers to refund
    assert organiser_email[:requires_manual_refund]
    assert_nil @event.waitships.find_by(account: buyer)
    assert_equal [Stripe::APIConnectionError, Mailgun::CommunicationError], reported.map(&:class)
  end

  test "a resold ticket whose refund email fails isn't left for the organisers to refund again" do
    create_event(prices: [15], enable_resales: true)
    @event.set(capacity: 1)
    ticket_type = @event.ticket_types.first
    account = FactoryBot.create(:account)
    order = Order.create!(event: @event, account: account, value: 15, payment_completed: true, payment_intent: 'pi_resold', currency: 'GBP')
    original = ticket_type.tickets.create!(event: @event, order: order, account: account, payment_completed: true, price: 15, payment_intent: 'pi_resold', made_available_at: Time.now)
    replacement = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 15)

    reported = []
    refunds = 0
    organiser_email = nil
    ErrorReporting.stub(:capture_exception, ->(e, **) { reported << e }) do
      Stripe::PaymentIntent.stub :retrieve, api_object(charges: [api_object(id: 'ch_resold')]) do
        Stripe::Refund.stub :create, proc { refunds += 1 } do
          Mailgun::Client.stub :new, proc { raise Mailgun::CommunicationError, 'Mailgun is down' } do
            replacement.stub :send_resale_notification_to_previous_ticketholder, nil do
              replacement.stub :send_resale_notification_to_organiser, proc { |_account, **kwargs| organiser_email = kwargs } do
                replacement.payment_completed!
              end
            end
          end
        end
      end
    end
    assert original.reload.deleted?
    assert_equal 1, refunds
    refute organiser_email[:requires_manual_refund]
    assert_equal [Mailgun::CommunicationError], reported.map(&:class)
  end

  test 'a sale reselling two tickets from an order with credit tells the organisers what the order paid' do
    covers 'events/resale-credit-email-says-order-total@33bfce'
    create_event(prices: [15], enable_resales: true)
    @event.set(capacity: 2)
    single = @event.ticket_types.first
    pair = @event.ticket_types.create!(name: 'Pair', price: 0, quantity: 10, slots: 2)
    account = FactoryBot.create(:account)
    order = Order.create!(event: @event, account: account, value: 20, credit_applied: 10, payment_completed: true, payment_intent: 'pi_credit', currency: 'GBP')
    2.times do |i|
      single.tickets.create!(event: @event, order: order, account: account, payment_completed: true, price: 15, payment_intent: 'pi_credit', made_available_at: (i + 1).minutes.ago)
    end
    replacement = pair.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 0)

    organiser_emails = []
    replacement.stub :send_resale_notification_to_previous_ticketholder, nil do
      replacement.stub :send_resale_notification_to_organiser, proc { |_account, **kwargs| organiser_emails << kwargs } do
        replacement.payment_completed!
      end
    end
    assert_equal 0, order.tickets.count
    assert_equal [20, 20], organiser_emails.pluck(:order_total)
  end

  test 'a sale while places are left leaves tickets on resale alone' do
    covers 'events/resale-only-when-full@d69dd8'
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 2)
    ticket_type = @event.ticket_types.first
    original = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: Time.now)
    sale = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 10)

    complete_without_notifications(sale)
    refute original.reload.deleted?
    assert original.made_available_at
  end

  test 'putting a ticket on resale at a sold-out event emails the waitlist' do
    covers 'events/resale-emails-waitlist@be56ac', 'events/resale-at-any-time@182662', 'events/waitlist-emailed-when-tickets-available@a5c6b3'
    Delayed::Job.delete_all
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 1)
    account = FactoryBot.create(:account)
    ticket = @event.ticket_types.first.tickets.create!(event: @event, account: account, payment_completed: true, price: 0)
    Waitship.create!(event: @event, account: FactoryBot.create(:account))
    assert Event.find(@event.id).sold_out_cache
    sign_in_with_rack(account)

    post "/tickets/#{ticket.id}/toggle_resale"
    assert ticket.reload.made_available_at
    assert_equal 1, Delayed::Job.and(handler: /send_waitlist_tickets_available/).count
  end

  test 'a resold ticket is refunded only its own price' do
    covers 'events/resold-ticket-refunded@81ebca', 'events/resale-refunds-own-price@2a9826', 'events/refund-ticket-own-price@985cff'
    create_event(prices: [15], enable_resales: true)
    @event.set(capacity: 2)
    ticket_type = @event.ticket_types.first
    account = FactoryBot.create(:account)
    order = Order.create!(event: @event, account: account, value: 30, payment_completed: true, payment_intent: 'pi_resold', currency: 'GBP')
    original = ticket_type.tickets.create!(event: @event, order: order, account: account, payment_completed: true, price: 15, payment_intent: 'pi_resold', made_available_at: Time.now)
    kept = ticket_type.tickets.create!(event: @event, order: order, account: account, payment_completed: true, price: 15, payment_intent: 'pi_resold')
    replacement = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 15)

    refund_params = []
    Stripe::PaymentIntent.stub :retrieve, api_object(charges: [api_object(id: 'ch_resold')]) do
      Stripe::Refund.stub :create, proc { |params, _opts| refund_params << params } do
        complete_without_notifications(replacement)
      end
    end
    assert original.reload.deleted?
    refute kept.reload.deleted?
    assert_equal [{ charge: 'ch_resold', amount: 1500 }], refund_params
  end

  test 'a resold ticket from an order with credit is left for the organiser to refund' do
    covers 'events/resale-credit-refunded-by-hand@33f9e9', 'events/resale-credit-email-says-order-total@33bfce'
    create_event(prices: [15], enable_resales: true)
    @event.set(capacity: 2)
    ticket_type = @event.ticket_types.first
    account = FactoryBot.create(:account)
    order = Order.create!(event: @event, account: account, value: 20, credit_applied: 10, payment_completed: true, payment_intent: 'pi_credit', currency: 'GBP')
    original = ticket_type.tickets.create!(event: @event, order: order, account: account, payment_completed: true, price: 15, payment_intent: 'pi_credit', made_available_at: Time.now)
    ticket_type.tickets.create!(event: @event, order: order, account: account, payment_completed: true, price: 15, payment_intent: 'pi_credit')
    replacement = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: false, price: 15)
    assert original.requires_manual_refund?
    assert_equal 20, order.total

    refunds = 0
    previous_ticketholder_email = organiser_email = nil
    Stripe::PaymentIntent.stub :retrieve, api_object(charges: [api_object(id: 'ch_credit')]) do
      Stripe::Refund.stub :create, proc { refunds += 1 } do
        replacement.stub :send_resale_notification_to_previous_ticketholder, proc { |_account, **kwargs| previous_ticketholder_email = kwargs } do
          replacement.stub :send_resale_notification_to_organiser, proc { |_account, **kwargs| organiser_email = kwargs } do
            replacement.payment_completed!
          end
        end
      end
    end
    assert original.reload.deleted?
    assert_equal 0, refunds
    assert previous_ticketholder_email[:requires_manual_refund]
    assert organiser_email[:requires_manual_refund]
    # What the order paid with both its tickets, not what it's worth once the resold one is gone
    assert_equal 20, organiser_email[:order_total]

    html = EmailHelper.html(:ticket_resale, account: replacement.account, event: @event, previous_account: account, **organiser_email)
    assert_includes html, 'used credit or a fixed discount'
    assert_includes html, 'the order paid £20 in all'
  end

  test "a resale emails the event's facilitators" do
    covers 'events/resale-emails-facilitators@2d3044'
    create_event(prices: [0], enable_resales: true)
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    ticket = @event.ticket_types.first.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0)
    previous_account = FactoryBot.create(:account)

    email = recorded_email { ticket.send_resale_notification_to_organiser(previous_account) }
    # The organisation's only admin was made a facilitator when the event was created
    assert_equal [@organisation.admins.first.email, facilitator.email].sort, email.recipients.sort
  end

  test "a resale that needs a manual refund emails the event's contacts and Dandelion admins" do
    covers 'events/resale-refund-fails@856deb'
    create_event(prices: [0], enable_resales: true)
    facilitator = FactoryBot.create(:account)
    @event.event_facilitations.create!(account: facilitator)
    admin = FactoryBot.create(:account, admin: true)
    ticket = @event.ticket_types.first.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0)
    previous_account = FactoryBot.create(:account)

    email = recorded_email { ticket.send_resale_notification_to_organiser(previous_account, requires_manual_refund: true) }
    assert_includes email.recipients, @event.account.email
    assert_includes email.recipients, facilitator.email
    assert_includes email.recipients, admin.email
  end

  test 'turning resales off at a full event gives the tickets on resale back to their holders' do
    covers 'events/resales-off-returns-tickets@ad509e'
    create_event(prices: [0], enable_resales: true)
    @event.set(capacity: 1)
    ticket_type = @event.ticket_types.first
    ticket = ticket_type.tickets.create!(event: @event, account: FactoryBot.create(:account), payment_completed: true, price: 0, made_available_at: Time.now)

    @event.update!(enable_resales: false)
    refute ticket.reload.deleted?
    assert_nil ticket.made_available_at
    assert Event.find(@event.id).sold_out?
  end
end
