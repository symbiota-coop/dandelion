module Delayed
  class Job
    class RunError < StandardError; end
    after_destroy do
      if last_error
        begin
          raise Delayed::Job::RunError, last_error.split("\n").first
        rescue StandardError => e
          Honeybadger.context({ last_error: last_error })
          Honeybadger.notify(e)
        end
      end
    end
  end
end
