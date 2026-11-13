# Holds a lock on a record while a block runs, so that a check and the write it allows can't interleave with another
# request's: two bookings each counting the last ticket and both taking it, say, or two checkouts spending the same
# credit. Only code that holds the same record's lock waits; nothing else is blocked.
#
# A lock is a document in the locks collection whose _id names the record ("Event:<id>"), so taking one is a single
# atomic upsert and needs no index of its own. A lock lasts LEASE seconds at most, so one left by a process that died
# holding it is taken over rather than blocking the record for good. A thread that already holds a record's lock can
# take it again (a booking's tickets inside the booking's lock on the event).
#
# Locks on several records are taken in the order given. Code that takes more than one should always take them in the
# same order, so two requests never each hold one the other is waiting for.
module RecordLock
  # Seconds to wait for the locks a hold takes, all of them together, before giving up with Busy
  WAIT = 25
  # Seconds a lock lasts, at most. Taken first, a lock is held while the hold waits for the others, so this is WAIT
  # and then much longer than anything that holds one should take
  LEASE = WAIT + 35

  # Other requests held the locks for longer than WAIT
  class Busy < StandardError; end

  module_function

  # deadline: when to give up waiting, shared by the locks one hold takes, so waiting for the later ones can't outlast
  # the earlier ones' leases
  def hold(*records, deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait, &block)
    record, *rest = records
    return yield unless record
    return hold(record, deadline: deadline) { hold(*rest, deadline: deadline, &block) } if rest.any?

    key = "#{record.class.name}:#{record.id}"
    held = (Thread.current[:record_locks] ||= Set.new)
    return yield if held.include?(key)

    token = acquire(key, deadline)
    held << key
    begin
      yield
    ensure
      held.delete(key)
      # Only if it's still ours: once its lease ran out, another request may have taken it
      collection.delete_one(_id: key, token: token)
    end
  end

  # Takes the lock if no one holds it or its lease has run out. If someone holds it, the upsert tries to insert a
  # second lock with the same _id, which fails, so it waits and tries again
  def acquire(key, deadline)
    token = SecureRandom.hex(8)
    begin
      now = Time.now.utc
      collection.update_one({ _id: key, expires_at: { '$lt' => now } }, { '$set' => { token: token, expires_at: now + LEASE } }, upsert: true)
      token
    rescue Mongo::Error::OperationFailure => e
      raise unless e.code == 11_000
      raise Busy, key if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      sleep 0.05
      retry
    end
  end

  # A method rather than WAIT, so tests can wait less
  def wait
    WAIT
  end

  def collection
    Mongoid.default_client[:locks]
  end

  # Validates and inserts a new record while holding a lock on the record it belongs to, so a validation that counts
  # that record's others (an option's capacity, a gathering's member limit, one membership each) sees every one saved
  # before it, and none is saved between its check and its insert: include RecordLock.on_insert(:option). Mongoid's
  # save, save!, create and create! all insert a new record through insert, which validates it
  def on_insert(association)
    Module.new do
      define_method(:insert) do |options = {}|
        parent = send(association)
        parent ? RecordLock.hold(parent) { super(options) } : super(options)
      end
    end
  end
end
