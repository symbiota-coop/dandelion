module RuboCop
  module Cop
    module Dandelion
      # Put field cleanup and `errors.add` in `before_validation`, not `validate do`.
      #
      # @example
      #   # bad
      #   validate do
      #     errors.add(:name, 'is too long') if name.length > 100
      #   end
      #
      #   # good
      #   before_validation do
      #     errors.add(:name, 'is too long') if name.length > 100
      #   end
      class ValidateBlock < Base
        MSG = 'Use `before_validation`, not `validate do`.'

        def on_block(node)
          send_node = node.send_node
          return unless send_node.receiver.nil? && send_node.method?(:validate) && !send_node.arguments?

          add_offense(send_node)
        end
        alias on_numblock on_block
        alias on_itblock on_block
      end
    end
  end
end
