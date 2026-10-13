module RuboCop
  module Cop
    module Dandelion
      # Use `validates_presence_of`, not `validates :name, presence: true`.
      #
      # @example
      #   # bad
      #   validates :name, presence: true
      #
      #   # good
      #   validates_presence_of :name
      class ValidatesPresence < Base
        MSG = 'Use `validates_presence_of`, not `validates ... presence:`.'
        RESTRICT_ON_SEND = %i[validates].freeze

        def_node_matcher :presence_option, <<~PATTERN
          (send nil? :validates ... (hash <$(pair (sym :presence) _) ...>))
        PATTERN

        def on_send(node)
          presence_option(node) { |pair| add_offense(pair) }
        end
      end
    end
  end
end
