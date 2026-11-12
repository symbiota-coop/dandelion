require 'rake/testtask'

test_tasks = Dir['test/*'].map { |f| (m = f.match(%r{test/(\w+)_test.rb})) ? m[1] : nil }.compact

# Individual test tasks (for running a single test file)
test_tasks.each do |t|
  Rake::TestTask.new("test:#{t}") do |test|
    test.pattern = "test/#{t}_test.rb"
  end
end

# Several test files in one process, as CI runs each group of them (.github/workflows/ruby.yml):
# TEST_FILES="accounts account_sign_ins" rake test:files
Rake::TestTask.new('test:files') do |test|
  test.test_files = ENV.fetch('TEST_FILES', '').split.map { |name| "test/#{name}_test.rb" }
end

# Main test task - runs ALL tests in a single process (server starts once)
desc 'Run application test suite'
Rake::TestTask.new(:test) do |test|
  test.pattern = 'test/*_test.rb'
end
