module RuboCop
  module Cop
    module Dandelion
      # Use `belongs_to_without_parent_validation`, not Mongoid `belongs_to` (its parent check fails when the parent is only in memory).
      #
      # @example
      #   # bad
      #   belongs_to :account
      #
      #   # good
      #   belongs_to_without_parent_validation :account
      class BelongsTo < Base
        MSG = 'Use `belongs_to_without_parent_validation`, not `belongs_to`.'
        RESTRICT_ON_SEND = %i[belongs_to].freeze

        def on_send(node)
          return if node.receiver

          add_offense(node.loc.selector)
        end
      end
    end
  end
end
