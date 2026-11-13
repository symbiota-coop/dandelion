require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

# RecordLock, and what holds one: bookings of an event, its discount codes and a buyer's credit, and joining an option
# or a gathering. Each holds the lock in another thread, as a request would, to show the code waits for it
class RecordLockTest < ActiveSupport::TestCase
  # Holds record's lock in another thread while the block runs
  def held_elsewhere(record)
    taken = Queue.new
    release = Queue.new
    thread = Thread.new do
      RecordLock.hold(record) do
        taken << true
        release.pop
      end
    end
    taken.pop
    yield
  ensure
    release << true
    thread&.join
  end

  # Waits less than requests do, so a lock held elsewhere fails fast
  def waiting_briefly(&)
    RecordLock.stub(:wait, 0.2, &)
  end

  def book_holding_locks(buyer, signed_in: false, discount_code: nil)
    OrderBuilder.new(
      event: @event, buyer: { name: buyer.name, email: buyer.email }, quantities: { @event.ticket_types.first.id.to_s => '1' },
      payment_method: 'rsvp', signed_in_account: (buyer if signed_in), discount_code: discount_code
    ).call
  end

  test "a record is locked by one request at a time, until it lets go or the lock's lease runs out" do
    create_event
    waiting_briefly do
      held_elsewhere(@event) { assert_raises(RecordLock::Busy) { RecordLock.hold(@event) { flunk 'held twice' } } }
      assert RecordLock.hold(@event) { true }
      # Holding it again inside, as a booking's tickets would
      assert RecordLock.hold(@event) { RecordLock.hold(@event) { true } }

      # Left by a process that died holding it
      RecordLock.collection.insert_one(_id: "Event:#{@event.id}", token: 'gone', expires_at: 1.minute.ago)
      assert RecordLock.hold(@event) { true }
      assert_equal 0, RecordLock.collection.count_documents
    end
  end

  test 'the locks a hold takes share one wait, so waiting for the later ones never outlasts the earlier ones' do
    create_event
    # The event is let go partway through the wait, and the organisation never is: the hold gives up once the wait is
    # over, not a whole wait after taking the event
    RecordLock.stub(:wait, 0.6) do
      held_elsewhere(@organisation) do
        release = Queue.new
        thread = Thread.new { RecordLock.hold(@event) { release.pop } }
        sleep 0.1 until RecordLock.collection.count_documents(_id: "Event:#{@event.id}") == 1
        Thread.new { sleep 0.4 and release << true }
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        assert_raises(RecordLock::Busy) { RecordLock.hold(@event, @organisation) { flunk 'held twice' } }
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.9
        thread.join
      end
    end
  end

  test 'a booking waits for other bookings of the event, its discount code and the buyer’s credit' do
    create_event(prices: [10])
    code = @event.discount_codes.create!(code: 'FREE', percentage_discount: 100, maximum_uses: 1)
    buyer = FactoryBot.create(:account)
    organisationship = @organisation.organisationships.create!(account: buyer)
    organisationship.creditings.create!(account: @account, amount: 10, currency: 'GBP')

    waiting_briefly do
      [[@event, {}], [code, { discount_code: 'FREE' }], [organisationship, { signed_in: true }]].each do |record, options|
        held_elsewhere(record) { assert_raises(OrderBuilder::Busy) { book_holding_locks(buyer, **options) } }
        assert_equal 0, @event.orders.count, record.class.name
      end
    end

    book_holding_locks(buyer, signed_in: true)
    assert_equal 10, @event.orders.first.credit_applied
  end

  test 'joining an option or a gathering waits for others joining it, and a full option takes no one' do
    create_gathering(privacy: 'open')
    option = @gathering.options.create!(name: 'Camping', type: 'Tier', capacity: 1, account: @account)
    member = FactoryBot.create(:account)

    waiting_briefly do
      held_elsewhere(@gathering) { assert_raises(RecordLock::Busy) { @gathering.memberships.create(account: member) } }
      @gathering.memberships.create!(account: member)
      held_elsewhere(option) { assert_raises(RecordLock::Busy) { option.optionships.create(account: member, gathering: @gathering) } }
    end

    # Without the records that weren't saved, which creating them added to the associations
    option.reload
    option.optionships.create!(account: member, gathering: @gathering)
    # Over capacity, as a race could once leave it: no one more gets in
    Optionship.collection.insert_one(account_id: FactoryBot.create(:account).id, option_id: option.id, gathering_id: @gathering.id)
    assert option.reload.full?
    refute option.optionships.create(account: FactoryBot.create(:account), gathering: @gathering).persisted?
  end
end
