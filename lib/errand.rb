# A step of a scheduled task (tasks/tasks.rake): prints its label as it starts and again with how long it took, also if
# it fails. Output is flushed line by line, as Render timestamps lines as they arrive and Ruby otherwise buffers them
# when writing to a pipe, so a whole run's lines came in a batch or two
module Errand
  def self.step(label)
    $stdout.sync = true
    puts label
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    yield
  ensure
    puts "#{label}: #{duration(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)}" if started
  end

  def self.duration(seconds)
    return format('%.1fs', seconds) if seconds < 60

    minutes, seconds = seconds.round.divmod(60)
    "#{minutes}m#{format('%02d', seconds)}s"
  end
end
