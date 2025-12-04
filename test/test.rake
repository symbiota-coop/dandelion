require 'rake/testtask'

test_tasks = Dir['test/*'].map { |f| (m = f.match(%r{test/(\w+)_test.rb})) ? m[1] : nil }.compact

# Individual test tasks (for running a single test file)
test_tasks.each do |t|
  Rake::TestTask.new("test:#{t}") do |test|
    test.pattern = "test/#{t}_test.rb"
  end
end

# Main test task - runs ALL tests in a single process (server starts once)
desc 'Run application test suite'
Rake::TestTask.new(:test) do |test|
  test.pattern = 'test/*_test.rb'
end
