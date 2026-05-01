class TestJob
  class TestJobError < StandardError; end

  def initialize(message: 'Test job error')
    @message = message
  end

  def perform
    raise TestJobError, @message
  end
end
