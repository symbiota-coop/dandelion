class RackUserAgentThrottler
  class << self
    attr_accessor :throttled_user_agents
  end

  def initialize(app)
    @app = app
    @last_request_times = {}
    @mutex = Mutex.new
  end

  def call(env)
    user_agent = env['HTTP_USER_AGENT'].to_s
    throttled_agents = self.class.throttled_user_agents || []

    # Check if user agent matches any throttled patterns
    matched_agent = throttled_agents.find { |pattern| user_agent.include?(pattern) }

    if matched_agent
      @mutex.synchronize do
        current_time = Time.now
        last_time = @last_request_times[matched_agent]

        # If last request was less than 60 seconds ago, throttle
        return [429, { 'Content-Type' => 'text/plain', 'Retry-After' => '60' }, ['Too Many Requests']] if last_time && (current_time - last_time) < 60

        @last_request_times[matched_agent] = current_time
      end
    end

    @app.call(env)
  end
end
