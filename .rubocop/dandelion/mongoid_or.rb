module RuboCop
  module Cop
    module Dandelion
      # Never use Mongoid `.or`: it ORs against whatever is already in the selector, so `Event.live.or(featured: true)` means live or featured.
      #
      # @example
      #   # bad
      #   Event.live.or({ featured: true }, { boosted: true })
      #
      #   # good
      #   Event.live.and('$or' => [{ featured: true }, { boosted: true }])
      class MongoidOr < Base
        MSG = "Don't use Mongoid `.or`, which ORs against the whole selector so far; use `.and('$or' => [...])`."
        RESTRICT_ON_SEND = %i[or].freeze

        def on_send(node)
          return unless node.receiver

          add_offense(node.loc.selector)
        end
        alias on_csend on_send
      end
    end
  end
end
