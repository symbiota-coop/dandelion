module RuboCop
  module Cop
    module Dandelion
      # Don't use `.presence`, on `params` or anywhere else.
      #
      # @example
      #   # bad
      #   name = params[:name].presence || 'Untitled'
      #
      #   # good
      #   name = params[:name] || 'Untitled'
      class Presence < Base
        MSG = "Don't use `.presence`."
        RESTRICT_ON_SEND = %i[presence].freeze

        def on_send(node)
          return unless node.receiver

          add_offense(node.loc.selector)
        end
        alias on_csend on_send
      end
    end
  end
end
