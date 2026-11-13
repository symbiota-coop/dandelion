require 'rake/testtask'

# Each named by its path in test/, as test:events/hosts
test_tasks = Dir['test/**/*_test.rb'].map { |f| f.delete_prefix('test/').delete_suffix('_test.rb') }

# Individual test tasks (for running a single test file)
test_tasks.each do |t|
  Rake::TestTask.new("test:#{t}") do |test|
    test.pattern = "test/#{t}_test.rb"
  end
end

# Several test files in one process, as CI runs each group of them (.github/workflows/ruby.yml):
# TEST_FILES="accounts/accounts accounts/sign_ins" rake test:files
Rake::TestTask.new('test:files') do |test|
  test.test_files = ENV.fetch('TEST_FILES', '').split.map { |name| "test/#{name}_test.rb" }
end

# TEST_FILES split between TEST_PROCESSES (default 2) runs of test:files at once, as CI runs each group: a run is mostly
# one Ruby process and one Chrome, and the runner has 4 CPUs. Each run has its own database, port and Chrome
# (config/boot.rb), so they can't clash. Files are split by how long they took last time, from TEST_TIMES_FILE (default
# tmp/test_times.json, which each run updates and CI caches between runs), or, with no time yet, by their number of tests
# at the average time a test took: biggest first, each to the run with least so far. Each run's output is printed whole
# once it's done, and the task fails if any run does.
# TEST_FILES="accounts/accounts accounts/sign_ins" rake test:parallel
task 'test:parallel' do
  times_file = ENV.fetch('TEST_TIMES_FILE', 'tmp/test_times.json')
  times = File.exist?(times_file) ? JSON.parse(File.read(times_file)) : {}
  tests_in = ->(path) { File.exist?(path) ? File.read(path, encoding: 'UTF-8').scan(/^\s*test\s+['"]/).length : 0 }
  per_test = times.empty? ? 1.0 : times.values.sum / [times.keys.sum(&tests_in), 1].max
  weights = ENV.fetch('TEST_FILES', '').split.to_h do |name|
    path = "test/#{name}_test.rb"
    [name, times[path] || (tests_in.call(path) * per_test)]
  end
  shares = Array.new([Integer(ENV.fetch('TEST_PROCESSES', '2')), weights.length].min) { [] }
  weights.sort_by { |_name, seconds| -seconds }.each do |name, _seconds|
    shares.min_by { |share| share.sum { |n| weights[n] } } << name
  end
  shares.each { |share| puts "Run of about #{share.sum { |n| weights[n] }.round}s: #{share.join(' ')}" }

  FileUtils.mkdir_p('tmp/test_runs')
  FileUtils.rm_rf('tmp/test_runs/times')
  runs = shares.map do |share|
    log = "tmp/test_runs/#{SecureRandom.hex(4)}.log"
    pid = Process.spawn({ 'TEST_FILES' => share.join(' '), 'TEST_TIMES' => 'tmp/test_runs/times' }, 'bundle', 'exec', 'rake', 'test:files', out: log, err: %i[child out])
    { pid: pid, files: share, log: log }
  end
  # Stopped (a timeout, Ctrl-C), stop the runs too
  %w[INT TERM].each do |signal|
    trap(signal) do
      runs.each { |run| Process.kill(signal, run[:pid]) rescue nil } # rubocop:disable Style/RescueModifier -- a run that's already finished has no process to stop
      exit 1
    end
  end

  failed = []
  until runs.empty?
    pid, status = Process.wait2
    run = runs.find { |r| r[:pid] == pid } or next
    runs.delete(run)
    puts "━━ #{run[:files].join(' ')}: #{status.success? ? 'passed' : 'failed'}"
    puts File.read(run[:log])
    File.delete(run[:log])
    failed << run[:files] unless status.success?
  end
  # This run's times replace those it has of the same files, for the next run to split by
  Dir['tmp/test_runs/times/*.json'].each { |path| times.merge!(JSON.parse(File.read(path))) }
  FileUtils.mkdir_p(File.dirname(times_file))
  File.write(times_file, JSON.pretty_generate(times.sort.to_h))
  abort "Failed: #{failed.map { |share| share.join(' ') }.join('; ')}" if failed.any?
end

# Main test task - runs ALL tests in a single process (server starts once)
desc 'Run application test suite'
Rake::TestTask.new(:test) do |test|
  test.pattern = 'test/**/*_test.rb'
end

# Collates the coverage CI's test groups recorded (COVERAGE, test/setup/coverage.rb), downloaded into coverage-groups/, into
# one report in coverage/, and writes its totals and least-covered files to GitHub's job summary when there is one
desc 'Collate test coverage from coverage-groups/*/.resultset.json'
task 'test:coverage' do
  require 'simplecov'
  require_relative 'setup/coverage'
  SimpleCov.collate(Dir['coverage-groups/*/.resultset.json'], &TestCoverage::CONFIG)
  result = SimpleCov.result
  summary = ["## Test coverage: #{result.covered_percent.round(1)}% of lines\n", '| Group | Lines | Covered |',
             '|---|--:|--:|']
  result.groups.each do |name, files|
    summary << "| #{name} | #{files.lines_of_code} | #{files.covered_percent.round(1)}% |"
  end
  summary += ["\n### Most uncovered lines\n", '| File | Uncovered lines | Covered |', '|---|--:|--:|']
  result.files.sort_by { |f| -f.missed_lines.count }.first(30).each do |f|
    summary << "| #{f.project_filename.delete_prefix('/')} | #{f.missed_lines.count} | #{f.covered_percent.round(1)}% |"
  end
  puts summary
  File.write(ENV['GITHUB_STEP_SUMMARY'], "#{summary.join("\n")}\n", mode: 'a') if ENV['GITHUB_STEP_SUMMARY']
end
