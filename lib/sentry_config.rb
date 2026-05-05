Sentry.init do |config|
  config.dsn = ENV['SENTRY_DSN']
  config.environment = ENV['RACK_ENV']
  if (commit = ENV['RENDER_GIT_COMMIT'])
    config.release = commit
  end

  config.send_default_pii = true
  config.enable_logs = true
  config.enabled_patches = [:logger]
  config.profiles_sample_rate = 1.0
  config.traces_sample_rate = 1.0
  config.profiler_class = Sentry::Vernier::Profiler

  config.before_send = lambda do |event, hint|
    exception = hint[:exception]
    next event unless exception

    error_type = exception.class.name
    error_message = exception.message.to_s
    should_ignore = [
      %w[Sinatra::NotFound SignalException].include?(error_type),
      error_type == 'Sinatra::BadRequest' && error_message.include?('invalid %-encoding'),
      error_type == 'Sinatra::BadRequest' && error_message.include?('Invalid multipart/form-data: EOFError'),
      error_type == 'Sinatra::BadRequest' && error_message.include?('Invalid multipart/form-data: Rack::Multipart::EmptyContentError'),
      error_type == 'ThreadError' && error_message.include?("can't be called from trap context"),
      error_type == 'Mongoid::Errors::Validations' && error_message.include?('Ticket type is full'),
      error_type == 'Mongoid::Errors::Validations' && error_message.include?('Ticket type is not available as sales have ended'),
      error_type == 'Errno::EIO' && error_message.include?('Input/output error'),
      error_type == 'Encoding::CompatibilityError' && error_message.include?('invalid byte sequence in UTF-8')
    ].any?

    should_ignore ? nil : event
  end
end
