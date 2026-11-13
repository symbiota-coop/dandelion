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
