require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class TicketTypesTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  test 'creating a ticket type generates a secret token' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first

    assert_equal ticket_type.token, ticket_type.public_id
    assert_match(/\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/, ticket_type.token)
  end

  test 'saving a legacy ticket type does not backfill a token' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.unset(:token)
    ticket_type.reload
    ticket_type.update_attributes!(name: 'Renamed')

    assert_nil ticket_type.reload.token
    assert_equal ticket_type.id.to_s, ticket_type.public_id
  end

  test 'secret ticket types are revealed by token, or by mongo id only if legacy' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.create!(name: 'Secret squirrel', price: 0, quantity: 10, hidden: true)

    get "/e/#{@event.slug}"
    refute_includes last_response.body, 'Secret squirrel'

    get "/e/#{@event.slug}?ticket_type_id=#{ticket_type.id}"
    refute_includes last_response.body, 'Secret squirrel'

    get "/e/#{@event.slug}?ticket_type_id=#{ticket_type.token}"
    assert_includes last_response.body, 'Secret squirrel'

    ticket_type.unset(:token)
    get "/e/#{@event.slug}?ticket_type_id=#{ticket_type.id}"
    assert_includes last_response.body, 'Secret squirrel'
  end
  test 'parses fixed price from price_or_range' do
    event = FactoryBot.build(:event)
    ticket_type = TicketType.new(event: event, price_or_range: '25', price_or_range_submitted: true, name: 'Standard', quantity: 10)

    assert ticket_type.valid?, ticket_type.errors.full_messages.join(', ')
    assert_equal 25.0, ticket_type.price
    assert_nil ticket_type.range_min
    assert_nil ticket_type.range_max
  end

  test 'parses price range from price_or_range' do
    event = FactoryBot.build(:event)
    ticket_type = TicketType.new(event: event, price_or_range: '10-100', price_or_range_submitted: true, name: 'Sliding scale', quantity: 10)

    assert ticket_type.valid?, ticket_type.errors.full_messages.join(', ')
    assert_nil ticket_type.price
    assert_equal 10.0, ticket_type.range_min
    assert_equal 100.0, ticket_type.range_max
    assert_equal '10-100', ticket_type.price_or_range
  end

  test 'remaining excludes tickets made available again' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 2)
    ticket_type.tickets.create!(event: @event, payment_completed: true)
    ticket_type.tickets.create!(event: @event, payment_completed: true, made_available_at: Time.now)

    assert_equal 1, ticket_type.remaining
    assert_equal 0, ticket_type.remaining_including_made_available
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

  test 'updates existing ticket type via nested attributes' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first

    assert @event.update_attributes(ticket_types_attributes: {
                                      '0' => {
                                        'id' => ticket_type.id.to_s,
                                        'name' => 'Updated pass',
                                        'quantity' => 5,
                                        'price' => 0
                                      }
                                    })

    ticket_type.reload
    assert_equal 'Updated pass', ticket_type.name
    assert_equal 5, ticket_type.quantity
  end

  test 'refreshing after nested ticket type saves loads the event once per refresh and skips unchanged writes' do
    create_event(prices: [0, 0, 0])
    event = Event.find(@event.id)
    attributes = event.ticket_types.each_with_index.to_h do |ticket_type, i|
      [i.to_s, { 'id' => ticket_type.id.to_s, 'name' => "Pass #{i}" }]
    end
    refreshes = 0
    event.define_singleton_method(:refresh_sold_out_cache_and_notify_waitlist) do
      refreshes += 1
      super()
    end
    commands = []
    subscriber = Object.new
    subscriber.define_singleton_method(:started) { |e| commands << e.command }
    subscriber.define_singleton_method(:succeeded) { |_| nil }
    subscriber.define_singleton_method(:failed) { |_| nil }
    Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)

    assert event.update_attributes(ticket_types_attributes: attributes)

    event_reads = commands.count { |c| c['find'] == 'events' }
    sold_out_cache_writes = commands.count { |c| c['update'] == 'ticket_types' && c['updates'].first['u'].fetch('$set', {}).key?('sold_out_cache') }
    assert_equal 3, refreshes
    assert_operator event_reads, :<=, refreshes
    assert_equal 0, sold_out_cache_writes
  ensure
    Mongoid.default_client.unsubscribe(Mongo::Monitoring::COMMAND, subscriber) if subscriber
  end

  test 'ticket type sold-out caches ignore unsaved event edits when the event is invalid' do
    create_event(prices: [0], capacity: 10)
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 5)

    event = Event.find(@event.id)
    refute event.update_attributes(name: nil, capacity: 0, ticket_types_attributes: {
                                     '0' => { 'id' => ticket_type.id.to_s, 'name' => 'Renamed' }
                                   })

    assert_equal 'Renamed', ticket_type.reload.name
    refute ticket_type.sold_out_cache
  end

  test 'nested ticket type changes still refresh sold-out caches when the event is invalid' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 1)
    ticket_type.tickets.create!(event: @event, payment_completed: true)
    assert ticket_type.reload.sold_out_cache

    event = Event.find(@event.id)
    refute event.update_attributes(name: nil, ticket_types_attributes: {
                                     '0' => { 'id' => ticket_type.id.to_s, 'quantity' => 2 }
                                   })

    refute ticket_type.reload.sold_out_cache
  end

  test 'changing event capacity refreshes sold-out caches' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.tickets.create!(event: @event, payment_completed: true)
    refute @event.reload.sold_out_cache

    assert @event.update_attributes(capacity: 1)

    assert @event.reload.sold_out_cache
    assert ticket_type.reload.sold_out_cache
  end

  test 'changing ticket group capacity refreshes sold-out caches' do
    create_event(prices: [0])
    ticket_group = @event.ticket_groups.create!(name: 'Group', capacity: 5)
    ticket_type = @event.ticket_types.first
    ticket_type.update_attributes!(ticket_group: ticket_group)
    ticket_type.tickets.create!(event: @event, payment_completed: true)
    refute ticket_type.reload.sold_out_cache

    ticket_group.update_attributes!(capacity: 1)

    assert ticket_type.reload.sold_out_cache
    assert @event.reload.sold_out_cache
  end

  test 'accepts slots via nested attributes' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first

    assert @event.update_attributes(ticket_types_attributes: {
                                      '0' => {
                                        'id' => ticket_type.id.to_s,
                                        'name' => ticket_type.name,
                                        'quantity' => ticket_type.quantity,
                                        'slots' => 2
                                      }
                                    })

    assert_equal 2, ticket_type.reload.slots
  end

  test 'destroys existing ticket type via nested attributes' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first

    assert @event.update_attributes(ticket_types_attributes: {
                                      '0' => { 'id' => ticket_type.id.to_s, '_destroy' => '1' }
                                    })

    refute TicketType.and(id: ticket_type.id).exists?
  end

  test 'ignores nested attributes for missing ticket type id' do
    create_event(prices: [0])
    original_count = @event.ticket_types.count
    stale_id = BSON::ObjectId.new

    assert @event.update_attributes(ticket_types_attributes: {
                                      '0' => {
                                        'id' => stale_id.to_s,
                                        'name' => 'Ghost pass',
                                        'quantity' => 1,
                                        'price' => 0
                                      }
                                    })

    assert_equal original_count, @event.reload.ticket_types.count
    refute @event.ticket_types.and(id: stale_id).exists?
  end

  test 'rejects nested destroy when id is not on event regardless of _destroy flag' do
    create_event(as: :event1, prices: [0])
    create_event(as: :event2, prices: [0])
    other_ticket_type = @event2.ticket_types.first
    attributes = {
      'id' => other_ticket_type.id.to_s,
      '_destroy' => '1'
    }

    assert @event1.reject_ticket_type_nested_attributes?(attributes),
           'reject_if must not skip association check just because _destroy is present'
    assert @event1.update_attributes(ticket_types_attributes: { '0' => attributes })
    assert TicketType.and(id: other_ticket_type.id).exists?,
           'ticket type from another event must not be destroyed'
  end

  test 'ignores nested attributes for ticket type from another event' do
    create_event(as: :event1, prices: [0])
    create_event(as: :event2, prices: [0])
    other_ticket_type = @event2.ticket_types.first

    assert @event1.update_attributes(ticket_types_attributes: {
                                       '0' => {
                                         'id' => other_ticket_type.id.to_s,
                                         'name' => 'Hijacked pass',
                                         'quantity' => 1,
                                         'price' => 0
                                       }
                                     })

    refute @event1.reload.ticket_types.and(id: other_ticket_type.id).exists?
    refute_equal 'Hijacked pass', other_ticket_type.reload.name
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Slots
  # ═══════════════════════════════════════════════════════════════════════════

  test 'nil slots is saved as 1' do
    create_event(prices: [0], capacity: 10)
    ticket_type = @event.ticket_types.first
    ticket_type.quantity = 10
    ticket_type.slots = nil

    assert ticket_type.save!
    assert_equal 1, ticket_type.reload.slots
    assert_equal 10, ticket_type.number_of_tickets_available_in_single_purchase
  end

  test 'rejects negative slots' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.slots = -1

    refute ticket_type.valid?
    assert_includes ticket_type.errors[:slots], 'must not be < 0'
  end

  test 'event places remaining uses slots rather than ticket count' do
    create_event(prices: [0], capacity: 10)
    ticket_type = @event.ticket_types.first
    ticket_type.set(slots: 2, quantity: 10)
    ticket_type.tickets.create!(event: @event, payment_completed: true)
    ticket_type.tickets.create!(event: @event, payment_completed: true, made_available_at: Time.now)

    assert_equal 8, @event.places_remaining
    assert_equal 2, @event.slots_taken
  end

  test 'add-on tickets with 0 slots do not reduce event capacity' do
    create_event(prices: [0], capacity: 1)
    main = @event.ticket_types.first
    main.set(quantity: 10, slots: 1)
    addon = FactoryBot.create(:ticket_type, event: @event, quantity: 10, slots: 0)

    main.tickets.create!(event: @event, payment_completed: true)
    addon.tickets.create!(event: @event, payment_completed: true)

    assert_equal 1, @event.slots_taken
    assert_equal 0, @event.places_remaining
    assert main.reload.sold_out?
    refute addon.reload.sold_out?
    assert_equal 9, addon.number_of_tickets_available_in_single_purchase
  end

  test 'couples tickets take two places from event capacity' do
    create_event(prices: [0], capacity: 3)
    ticket_type = @event.ticket_types.first
    ticket_type.set(slots: 2, quantity: 10)

    assert_equal 1, ticket_type.number_of_tickets_available_in_single_purchase

    ticket_type.tickets.create!(event: @event, payment_completed: true)

    assert_equal 1, @event.places_remaining
    assert_equal 0, ticket_type.reload.number_of_tickets_available_in_single_purchase
    assert ticket_type.sold_out?
  end

  test 'ticket group places remaining uses slots' do
    create_event(prices: [0])
    ticket_group = @event.ticket_groups.create!(name: 'Saturday', capacity: 3)
    ticket_type = @event.ticket_types.first
    ticket_type.set(ticket_group_id: ticket_group.id, slots: 2, quantity: 10)

    assert_equal 1, ticket_type.number_of_tickets_available_in_single_purchase

    ticket_type.tickets.create!(event: @event, payment_completed: true)

    assert_equal 1, ticket_group.places_remaining
    assert_equal 2, ticket_group.slots_taken
    assert_equal 0, ticket_type.reload.number_of_tickets_available_in_single_purchase
  end

  test 'add-on tickets with 0 slots do not reduce ticket group capacity' do
    create_event(prices: [0])
    ticket_group = @event.ticket_groups.create!(name: 'Saturday', capacity: 1)
    main = @event.ticket_types.first
    main.set(ticket_group_id: ticket_group.id, quantity: 10, slots: 1)
    addon = FactoryBot.create(:ticket_type, event: @event, ticket_group: ticket_group, quantity: 10, slots: 0)

    main.tickets.create!(event: @event, payment_completed: true)
    addon.tickets.create!(event: @event, payment_completed: true)

    assert_equal 1, ticket_group.slots_taken
    assert_equal 0, ticket_group.places_remaining
    assert main.reload.sold_out?
    refute addon.reload.sold_out?
  end

  test 'creating a ticket refreshes remaining and sold_out? on the same event' do
    create_event(prices: [0], capacity: 1)
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 1)

    assert_equal 1, ticket_type.remaining
    refute @event.sold_out?

    ticket_type.tickets.create!(event: @event, payment_completed: true)

    assert_equal 0, ticket_type.remaining
    assert @event.sold_out?
    refute @event.ticket_type_waitlists_available?
  end

  test 'restoring a ticket refreshes remaining and sold_out? on the same event' do
    create_event(prices: [0], capacity: 1)
    ticket_type = @event.ticket_types.first
    ticket_type.set(quantity: 1)
    ticket = ticket_type.tickets.create!(event: @event, payment_completed: true)
    ticket.destroy

    assert_equal 1, ticket_type.remaining
    refute @event.sold_out?

    ticket.restore

    assert_equal 0, ticket_type.remaining
    assert @event.sold_out?
  end

  test 'destroying a ticket type refreshes sold_out? on the same event' do
    create_event(prices: [0, 0])
    sold_out_type, available_type = @event.ticket_types.to_a
    sold_out_type.set(quantity: 1)
    available_type.set(quantity: 1)
    sold_out_type.tickets.create!(event: @event, payment_completed: true)

    refute @event.sold_out?

    available_type.destroy

    assert @event.sold_out?
  end

  test 'duplicating an event copies ticket type slots' do
    create_event(prices: [0])
    @event.ticket_types.first.set(slots: 2)

    duplicate = @event.duplicate!(@account)

    assert_equal 2, duplicate.ticket_types.first.slots
  end

  # ═══════════════════════════════════════════════════════════════════════════
  # Quantity formula in description
  # ═══════════════════════════════════════════════════════════════════════════

  def create_role_balance_event(follower_description: '[=Leader*1.1:15]', follower_quantity: 80)
    create_event(prices: [0])
    @leader = @event.ticket_types.first
    @leader.set(name: 'Leader', quantity: 50)
    @follower = FactoryBot.create(
      :ticket_type,
      event: @event,
      name: 'Follower',
      quantity: follower_quantity,
      description: follower_description
    )
    @event.reload
    @leader = @event.ticket_types.detect { |ticket_type| ticket_type.name == 'Leader' }
    @follower = @event.ticket_types.detect { |ticket_type| ticket_type.name == 'Follower' }
  end

  test 'public_description strips a valid quantity formula' do
    ticket_type = TicketType.new(description: 'For followers only [=Leader*1.1:15]')

    assert_equal 'For followers only', ticket_type.public_description
  end

  test 'public_description is blank when the description is only a formula' do
    ticket_type = TicketType.new(description: '[=Leader*1.1:15]')

    assert_nil ticket_type.public_description
  end

  test 'public_description keeps invalid formula-like text' do
    ticket_type = TicketType.new(description: 'See notes [=Leader]')

    assert_equal 'See notes [=Leader]', ticket_type.public_description
    assert_nil ticket_type.quantity_formula
  end

  test 'quantity formula requires a non-whitespace name' do
    ticket_type = TicketType.new(name: 'Follower', quantity: 80, description: '[= *1.1:15]')

    assert_nil ticket_type.quantity_formula
    assert_equal 80, ticket_type.effective_quantity
    assert_equal '[= *1.1:15]', ticket_type.public_description
  end

  test 'quantity formula rejects a non-finite multiplier' do
    ticket_type = TicketType.new(name: 'Follower', quantity: 80, description: "[=Leader*#{'9' * 400}:15]")

    assert_nil ticket_type.quantity_formula
    assert_equal 80, ticket_type.effective_quantity
    assert_equal "[=Leader*#{'9' * 400}:15]", ticket_type.public_description
  end

  test 'quantity formula uses the minimum when no matching tickets have sold' do
    create_role_balance_event

    assert_equal 15, @follower.effective_quantity
    assert_equal 15, @follower.remaining
    refute @follower.sold_out?
  end

  test 'quantity formula releases more tickets as matching types sell' do
    create_role_balance_event
    20.times { @leader.tickets.create!(event: @event, payment_completed: true) }
    @event.reload
    @follower = @event.ticket_types.detect { |ticket_type| ticket_type.name == 'Follower' }

    assert_equal 22, @follower.effective_quantity
    assert_equal 22, @follower.remaining
  end

  test 'quantity formula never exceeds the ticket type quantity' do
    create_role_balance_event(follower_quantity: 18)
    20.times { @leader.tickets.create!(event: @event, payment_completed: true) }
    @event.reload
    @follower = @event.ticket_types.detect { |ticket_type| ticket_type.name == 'Follower' }

    assert_equal 18, @follower.effective_quantity
    assert_equal 18, @follower.remaining
  end

  test 'quantity formula without a minimum starts at zero' do
    create_role_balance_event(follower_description: '[=Leader*1.1]')

    assert_equal 0, @follower.effective_quantity
    assert_equal 0, @follower.remaining
    assert @follower.sold_out?
  end

  test 'quantity formula sums all other types whose names include the token' do
    create_role_balance_event
    early = FactoryBot.create(:ticket_type, event: @event, name: 'Leader early bird', quantity: 20)
    3.times { @leader.tickets.create!(event: @event, payment_completed: true) }
    7.times { early.tickets.create!(event: @event, payment_completed: true) }
    @event.reload
    @follower = @event.ticket_types.detect { |ticket_type| ticket_type.name == 'Follower' }

    assert_equal 15, @follower.effective_quantity

    10.times { early.tickets.create!(event: @event, payment_completed: true) }
    @event.reload
    @follower = @event.ticket_types.detect { |ticket_type| ticket_type.name == 'Follower' }

    assert_equal 22, @follower.effective_quantity
  end

  test 'quantity formula does not count the type it is written on' do
    create_event(prices: [0])
    ticket_type = @event.ticket_types.first
    ticket_type.set(name: 'Leader', quantity: 10)
    5.times { ticket_type.tickets.create!(event: @event, payment_completed: true) }
    ticket_type.set(description: '[=Leader*1.1:0]')

    assert_equal 0, ticket_type.effective_quantity
    assert_equal(-5, ticket_type.remaining)
  end

  test 'invalid quantity formula leaves quantity unchanged' do
    create_role_balance_event(follower_description: 'Bring shoes [=Leader]')

    assert_equal 80, @follower.effective_quantity
    assert_equal 80, @follower.remaining
    assert_equal 'Bring shoes [=Leader]', @follower.public_description
  end

  test 'quantity formula accepts spaces inside the suffix' do
    create_role_balance_event(follower_description: '[=Leader * 1.1 : 15]')

    assert_equal({ name: 'Leader', multiplier: 1.1, min: 15 }, @follower.quantity_formula)
    assert_equal 15, @follower.effective_quantity
  end

  test 'selling a linked ticket type can unsell-out a formula ticket type' do
    create_role_balance_event(follower_description: '[=Leader*1.1]', follower_quantity: 10)
    assert @follower.sold_out?

    @leader.tickets.create!(event: @event, payment_completed: true)
    @event.reload
    @follower = @event.ticket_types.detect { |ticket_type| ticket_type.name == 'Follower' }

    refute @follower.sold_out?
    assert_equal 1, @follower.remaining
    refute @follower.sold_out_cache
  end

  test 'duplicating an event copies a quantity formula description' do
    create_role_balance_event
    duplicate = @event.duplicate!(@account)
    follower = duplicate.ticket_types.detect { |ticket_type| ticket_type.name == 'Follower' }

    assert_equal '[=Leader*1.1:15]', follower.description
    assert_equal 15, follower.effective_quantity
  end
end

