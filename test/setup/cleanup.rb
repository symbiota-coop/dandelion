# Clearing up after runs: each run's database and screenshots, and those of runs that didn't finish
test_run_running = lambda do |pid|
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

# Drop this run's database (see config/boot.rb) when it ends, and any left by runs that didn't finish
Mongoid.default_client.database_names.grep(/\Adandelion_test_(\d+)\z/) do |name|
  Mongoid.default_client.use(name).database.drop unless test_run_running.call(Regexp.last_match(1).to_i)
end
Minitest.after_run { Mongoid.default_client.database.drop }

# Remove the screenshots of runs that have finished, once they're an hour old
Dir.glob('capybara/*/').each do |dir|
  pid = File.basename(dir)
  FileUtils.rm_rf(dir) if pid.match?(/\A\d+\z/) && !test_run_running.call(pid.to_i) && File.mtime(dir) < 1.hour.ago
rescue Errno::ENOENT
  # Another run starting at the same time removed it first
end
