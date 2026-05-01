# frozen_string_literal: true

require 'yaml'

# Unified API for Honeybadger or Sentry (see config/error_tracking.yml and ERROR_TRACKING_BACKEND).
module ErrorTracking
  class << self
    attr_reader :backend_name

    def bootstrap!(root:)
      path = ENV.fetch(
        'ERROR_TRACKING_CONFIG',
        File.join(root, 'config', 'error_tracking.yml')
      )
      raw = File.exist?(path) ? YAML.safe_load(File.read(path), permitted_classes: [Symbol]) || {} : {}
      @backend_name = (ENV['ERROR_TRACKING_BACKEND'] || raw['backend'] || 'none').to_s.downcase.tr('-', '_').to_sym

      case @backend_name
      when :honeybadger
        require 'honeybadger'
        Honeybadger.configure do |config|
          config.before_notify do |notice|
            notice.halt! if ErrorTracking.notice_filtered?(notice)
          end
        end
      when :sentry
        require 'sentry-ruby'
        raise 'SENTRY_DSN must be set when error_tracking backend is sentry' if ENV['SENTRY_DSN'].to_s.strip.empty?

        Sentry.init do |config|
          config.dsn = ENV['SENTRY_DSN']
          config.environment = ENV['RACK_ENV'] || 'development'
          config.enabled_environments = sentry_enabled_environments
        end
      when :none
        # no-op
      else
        raise ArgumentError, "Unknown error_tracking backend: #{@backend_name.inspect} " \
                             '(expected honeybadger, sentry, or none)'
      end
    end

    # Used by Honeybadger before_notify (block runs with a different self).
    def notice_filtered?(notice)
      should_ignore?(notice)
    end

    def notify(exception, options = {})
      return if skip_notification?(exception, options)

      case @backend_name
      when :honeybadger
        Honeybadger.notify(exception, options)
      when :sentry
        Sentry.capture_exception(exception, **sentry_capture_options(options))
      end
    end

    def context(hash)
      case @backend_name
      when :honeybadger
        Honeybadger.context(hash)
      when :sentry
        Sentry.configure_scope do |scope|
          scope.set_context('app', stringify_keys(hash))
        end
      end
    end

    def use_rack(builder)
      case @backend_name
      when :honeybadger
        builder.use Honeybadger::Rack::UserFeedback
        builder.use Honeybadger::Rack::UserInformer
        builder.use Honeybadger::Rack::ErrorNotifier
      when :sentry
        builder.use Sentry::Rack::CaptureExceptions
      end
    end

    private

    def skip_notification?(exception, options)
      return true if @backend_name == :none
      return false unless exception

      notice_like = Struct.new(:exception, :error_message).new(exception, exception.message)
      should_ignore?(notice_like)
    end

    def should_ignore?(notice)
      error_type = notice.exception.class.name
      error_message = notice.error_message

      [
        %w[Sinatra::NotFound SignalException].include?(error_type),
        error_type == 'Sinatra::BadRequest' && error_message&.include?('invalid %-encoding'),
        error_type == 'Sinatra::BadRequest' && error_message&.include?('Invalid multipart/form-data: EOFError'),
        error_type == 'Sinatra::BadRequest' && error_message&.include?('Invalid multipart/form-data: Rack::Multipart::EmptyContentError'),
        error_type == 'ThreadError' && error_message&.include?("can't be called from trap context"),
        error_type == 'Mongoid::Errors::Validations' && error_message&.include?('Ticket type is full'),
        error_type == 'Mongoid::Errors::Validations' && error_message&.include?('Ticket type is not available as sales have ended'),
        error_type == 'Errno::EIO' && error_message&.include?('Input/output error'),
        error_type == 'Encoding::CompatibilityError' && error_message&.include?('invalid byte sequence in UTF-8')
      ].any?
    end

    def sentry_capture_options(options)
      tags = {}
      extra = {}

      options.each do |key, value|
        case key.to_sym
        when :context
          extra.merge!(stringify_keys(value))
        when :component
          tags['component'] = value.to_s
        when :action
          tags['action'] = value.to_s
        else
          extra[key.to_s] = value
        end
      end

      result = {}
      result[:tags] = tags if tags.any?
      result[:extra] = extra if extra.any?
      result
    end

    def stringify_keys(hash)
      hash.transform_keys(&:to_s)
    end

    def sentry_enabled_environments
      raw = ENV['SENTRY_ENABLED_ENVIRONMENTS'].to_s.strip
      return raw.split(',').map(&:strip).reject(&:empty?) unless raw.empty?

      %w[production staging]
    end
  end
end
