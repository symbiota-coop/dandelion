module RuboCop
  module Cop
    module Dandelion
      # Mongo indexes are created in the database, not declared in models with Mongoid's `index`.
      #
      # @example
      #   # bad
      #   index({ slug: 1 }, { unique: true })
      #
      #   # good
      #   validates_uniqueness_of :slug
      class MongoidIndex < Base
        MSG = 'Mongo indexes are created in the database, not declared in models.'
        RESTRICT_ON_SEND = %i[index].freeze

        def on_send(node)
          return if node.receiver || !node.arguments?

          add_offense(node.loc.selector)
        end
      end
    end
  end
end
