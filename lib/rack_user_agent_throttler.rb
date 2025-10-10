class RackUserAgentThrottler
  class << self
    attr_accessor :throttles
  end

  def initialize(app)
    @app = app
    @last_request_times = {}
    @mutex = Mutex.new
  end

  def call(env)
    user_agent = env['HTTP_USER_AGENT'].to_s
    request_path = env['PATH_INFO'].to_s
    throttles = self.class.throttles || {}

    # Check if user agent matches any throttled patterns (case-insensitive)
    matched_agent_pattern = throttles.keys.find { |pattern| user_agent.downcase.include?(pattern.downcase) }

    if matched_agent_pattern
      # Check if the request path matches any of the paths for this agent
      throttled_paths = throttles[matched_agent_pattern]
      matched_path = throttled_paths.find { |path| request_path == path }

      if matched_path
        throttle_key = "#{matched_agent_pattern}:#{matched_path}"

        @mutex.synchronize do
          current_time = Time.now
          last_time = @last_request_times[throttle_key]

          # If last request was less than 60 seconds ago, throttle
          return [429, { 'Content-Type' => 'text/plain', 'Retry-After' => '60' }, ['Too Many Requests']] if last_time && (current_time - last_time) < 60

          @last_request_times[throttle_key] = current_time
        end
      end
    end

    @app.call(env)
  end
end
