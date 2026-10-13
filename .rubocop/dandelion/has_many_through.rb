module RuboCop
  module Cop
    module Dandelion
      # Use `has_many_through` for join collections, not `has_many :x, through:`, which Mongoid ignores.
      #
      # @example
      #   # bad
      #   has_many :events, through: :event_facilitations
      #
      #   # good
      #   has_many_through :events, through: :event_facilitations
      class HasManyThrough < Base
        MSG = 'Mongoid has no `through:`; use `has_many_through`.'
        RESTRICT_ON_SEND = %i[has_many].freeze

        def_node_matcher :through_option, <<~PATTERN
          (send nil? :has_many ... (hash <$(pair (sym :through) _) ...>))
        PATTERN

        def on_send(node)
          through_option(node) { add_offense(node.loc.selector) }
        end
      end
    end
  end
end
