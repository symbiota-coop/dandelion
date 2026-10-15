module RuboCop
  module Cop
    module Dandelion
      # Use `.and`, not `.where`. To compare two fields, use `$expr` (Mongoid rejects JavaScript `$where` strings).
      #
      # @example
      #   # bad
      #   events.where(locked: false)
      #
      #   # good
      #   events.and(locked: false)
      #   memberships.and('$expr' => { '$lt' => ['$paid', '$requested_contribution'] })
      class MongoidWhere < Base
        MSG = 'Use `.and`, not `.where`.'
        RESTRICT_ON_SEND = %i[where].freeze

        def on_send(node)
          add_offense(node.loc.selector)
        end
        alias on_csend on_send
      end
    end
  end
end
