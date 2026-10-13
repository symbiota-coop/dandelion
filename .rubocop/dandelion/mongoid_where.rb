module RuboCop
  module Cop
    module Dandelion
      # Use `.and`, not `.where`, apart from a JavaScript `$where` string, which `.and` can't take.
      #
      # @example
      #   # bad
      #   events.where(locked: false)
      #
      #   # good
      #   events.and(locked: false)
      #   memberships.where('this.paid < this.requested_contribution')
      class MongoidWhere < Base
        MSG = 'Use `.and`, not `.where`.'
        RESTRICT_ON_SEND = %i[where].freeze

        def on_send(node)
          return if node.arguments.one? && node.first_argument.type?(:str, :dstr)

          add_offense(node.loc.selector)
        end
        alias on_csend on_send
      end
    end
  end
end
