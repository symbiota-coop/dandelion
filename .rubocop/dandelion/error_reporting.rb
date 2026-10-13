module RuboCop
  module Cop
    module Dandelion
      # Report rescued errors with `ErrorReporting.capture_exception(e, context:, tags:)`, not Sentry directly.
      #
      # @example
      #   # bad
      #   Sentry.capture_exception(e)
      #
      #   # good
      #   ErrorReporting.capture_exception(e, context: { order_id: order.id })
      class ErrorReporting < Base
        MSG = 'Use `ErrorReporting.capture_exception(e, context:, tags:)`, not `Sentry.%<method>s`.'
        RESTRICT_ON_SEND = %i[capture_exception capture_message].freeze

        def_node_matcher :sentry_call?, '(send (const {nil? cbase} :Sentry) _ ...)'

        def on_send(node)
          return unless sentry_call?(node)

          add_offense(node, message: format(MSG, method: node.method_name))
        end
      end
    end
  end
end
