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

unless defined?(SentryMongoCommandSubscriber)
  class SentryMongoCommandSubscriber
    SPAN_ORIGIN = 'auto.db.mongo'

    def initialize
      @spans = {}
      @mutex = Mutex.new
    end

    def started(event)
      return unless Sentry.initialized?

      parent_span = Sentry.get_current_scope.get_span
      return unless parent_span

      span = parent_span.start_child(
        op: 'db.query',
        description: description_for(event),
        origin: SPAN_ORIGIN
      )
      record_common_data(span, event)

      @mutex.synchronize { @spans[span_key(event)] = span }
    end

    def succeeded(event)
      finish(event, 'ok')
    end

    def failed(event)
      finish(event, 'internal_error') do |span|
        span.set_data('db.mongo.failure', event.message)
      end
    end

    private

    def finish(event, status)
      span = @mutex.synchronize { @spans.delete(span_key(event)) }
      return unless span

      span.set_status(status)
      span.set_data('db.duration_ms', (event.duration.to_f * 1000).round(2))
      yield(span) if block_given?
      span.finish(end_timestamp: span.start_timestamp + event.duration.to_f)
    end

    def record_common_data(span, event)
      span.set_data(Sentry::Span::DataConventions::DB_SYSTEM, 'mongodb')
      span.set_data(Sentry::Span::DataConventions::DB_NAME, event.database_name)
      span.set_data(Sentry::Span::DataConventions::SERVER_ADDRESS, event.address.host)
      span.set_data(Sentry::Span::DataConventions::SERVER_PORT, event.address.port)
      span.set_data('db.operation', event.command_name)

      collection = collection_for(event)
      span.set_data('db.collection.name', collection) if collection
    end

    def description_for(event)
      collection = collection_for(event)
      parts = [event.command_name]
      parts << collection if collection
      parts.join(' ')
    end

    def collection_for(event)
      command = event.command
      value = command['collection'] || command[:collection] || command[event.command_name] || command[event.command_name.to_sym]
      return if value.nil? || value == 1
      return if defined?(BSON::Int64) && value.is_a?(BSON::Int64)
      return if value.is_a?(Numeric)

      value.to_s
    end

    def span_key(event)
      [event.operation_id, event.request_id, event.address.to_s]
    end
  end
end

if defined?(Mongo::Monitoring) && !defined?(SENTRY_MONGO_COMMAND_SUBSCRIBER)
  SENTRY_MONGO_COMMAND_SUBSCRIBER = SentryMongoCommandSubscriber.new
  Mongo::Monitoring::Global.subscribe(Mongo::Monitoring::COMMAND, SENTRY_MONGO_COMMAND_SUBSCRIBER)

  if defined?(Mongoid::Clients)
    Mongoid::Clients.clients.each_value do |client|
      client.subscribe(Mongo::Monitoring::COMMAND, SENTRY_MONGO_COMMAND_SUBSCRIBER)
    end
  end
end
