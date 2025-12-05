module Delayed
  module Plugins
    class HoneybadgerNotifier < Delayed::Plugin
      callbacks do |lifecycle|
        lifecycle.around(:invoke_job) do |job, *args, &block|
          block.call(job, *args)
        rescue Exception => e # rubocop:disable Lint/RescueException
          handler = job.payload_object
          job_info = {
            job_id: job.id.to_s,
            handler_class: handler.class.name,
            attempts: job.attempts,
            queue: job.queue,
            run_at: job.run_at,
            created_at: job.created_at
          }
          if handler.respond_to?(:object)
            obj = handler.object
            job_info[:object_class] = obj.class.name
            job_info[:object_id] = obj.id.to_s if obj.respond_to?(:id)
          end
          if handler.respond_to?(:method_name)
            job_info[:method_name] = handler.method_name
          end
          Honeybadger.context(job_info)
          Honeybadger.notify(e, component: 'delayed_job', action: job_info[:method_name] || handler.class.name)
          raise
        end
      end
    end
  end
end

Delayed::Worker.plugins << Delayed::Plugins::HoneybadgerNotifier

class TestJob
  class TestJobError < StandardError; end

  def initialize(message: 'Test job error')
    @message = message
  end

  def perform
    raise TestJobError, @message
  end
end
