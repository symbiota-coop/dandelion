module RuboCop
  module Cop
    module Dandelion
      # A test file doesn't do itself what a shared helper in test/helpers does, so that code is written once and a fix
      # to it reaches every test (AGENTS.md, Tests): signing a Stripe webhook, counting the commands sent to MongoDB,
      # and finding or running queued jobs by their handler. Each was once copied, under several names, across files.
      #
      # @example
      #   # bad
      #   Stripe::Webhook::Signature.compute_signature(timestamp, payload, secret)
      #   Mongoid.default_client.subscribe(Mongo::Monitoring::COMMAND, subscriber)
      #   Delayed::Job.and(handler: /send_tickets/).each(&:invoke_job)
      #   Delayed::Job.all.select { |job| job.handler.match?(/send_tickets/) }
      #
      #   # good
      #   deliver_stripe_webhook('/organisations/stripe_connect_webhook', payload, secret: secret)
      #   commands = mongo_commands_during { get '/events' }
      #   run_jobs(:send_tickets)
      #   queued_jobs(:send_tickets).select { |job| job.handler.include?("session_id: #{id}\n") }
      class TestSharedHelper < Base
        MSG = '%<helper>s, rather than doing what it does here.'
        STRIPE = 'Sign Stripe webhooks with `deliver_stripe_webhook` or `stripe_signature_header` (CheckoutWebhookHelpers)'.freeze
        MONGO = 'Count the commands sent to MongoDB with `mongo_commands_during` (TestHelpers)'.freeze
        JOBS = 'Find and run queued jobs with `queued_jobs`, `run_jobs` or `emails_sent_by_jobs` (TestHelpers)'.freeze

        def_node_matcher :stripe_signature, '(const (const (const {nil? cbase} :Stripe) :Webhook) :Signature)'
        def_node_matcher :mongo_monitoring, '(const (const (const {nil? cbase} :Mongo) :Monitoring) :COMMAND)'
        def_node_matcher :jobs_by_handler, <<~PATTERN
          (send (const (const {nil? cbase} :Delayed) :Job) {:and :where :find_by :find_by! :exists?} (hash <(pair (sym :handler) _) ...>))
        PATTERN
        def_node_matcher :handler_matched, '(send (send _ :handler) {:match? :=~ :scan} regexp)'

        def on_const(node)
          offend(node, STRIPE) if stripe_signature(node)
          offend(node, MONGO) if mongo_monitoring(node)
        end

        def on_send(node)
          offend(node, JOBS) if jobs_by_handler(node) || handler_matched(node)
        end

        private

        def offend(node, helper)
          add_offense(node, message: format(MSG, helper: helper))
        end
      end
    end
  end
end
