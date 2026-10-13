module RuboCop
  module Cop
    module Dandelion
      # Query filters are class methods that return `self.and(...)` so they chain, not `scope :live, -> { ... }`.
      #
      # @example
      #   # bad
      #   scope :live, -> { where(locked: false) }
      #
      #   # good
      #   def self.live
      #     self.and(locked: false)
      #   end
      class MongoidScope < Base
        MSG = 'Define query filters as class methods that return `self.and(...)`, not with `scope`.'
        RESTRICT_ON_SEND = %i[scope].freeze

        def on_send(node)
          return if node.receiver
          return unless node.first_argument&.sym_type?

          add_offense(node.loc.selector)
        end
      end
    end
  end
end
