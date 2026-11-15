# Racing threads, for checks that hold a lock (RecordLock) so two requests at the same time can't both pass them
module RaceHelpers
  # Runs the block in count threads at once: each sets up first (it's given a gate to wait at), and they're let through
  # together. Gives what each returned or raised
  def race(count, &block)
    gate = Queue.new
    ready = Queue.new
    threads = Array.new(count) do |index|
      Thread.new do
        Thread.current.report_on_exception = false
        wait = lambda do
          ready << true
          gate.pop
        end
        block.call(index, wait)
      end
    end
    count.times { ready.pop }
    count.times { gate << true }
    threads.map do |thread|
      thread.value
    rescue StandardError => e
      e
    end
  end
end
