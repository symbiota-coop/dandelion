# How long each test file's tests took, for rake test:parallel to split the next run's files evenly: with TEST_TIMES set
# to a folder, each run writes its files' seconds there as <pid>.json, retries included, as they take the time too
module TestTimes
  SECONDS = Hash.new(0.0)

  # Adds a test's time since started (a monotonic clock reading) to its file's
  def self.record(klass, method_name, started)
    file = klass.instance_method(method_name).source_location.first.delete_prefix("#{Dir.pwd}/")
    SECONDS[file] += Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  end
end

if ENV['TEST_TIMES'].present?
  Minitest.after_run do
    FileUtils.mkdir_p(ENV['TEST_TIMES'])
    File.write(File.join(ENV['TEST_TIMES'], "#{Process.pid}.json"), TestTimes::SECONDS.transform_values { |seconds| seconds.round(1) }.to_json)
  end
end
