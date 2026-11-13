module RuboCop
  module Cop
    module Dandelion
      # Cuprite's `fill_in` blurs the field once it's typed in, which fires its change and blur handlers, so a field that
      # saves on either has saved by then. A `send_keys(:tab)` after it races that save: when the save replaces the field
      # (a pagelet reloading, say), the keys go to a node that's gone, and Cuprite raises ObsoleteNode, or
      # ElementNotFound, only some of the time. Drop it, and assert what the save shows.
      #
      # @example
      #   # bad
      #   find_field('price').send_keys(:tab)
      #   find_field('threshold').fill_in(with: 2).send_keys(:tab)
      #   page.send_keys(:tab)
      #
      #   # good
      #   fill_in 'price', with: '10'
      #   assert page.has_content?('Saved')
      #   find_field('search').send_keys(:enter)
      class CapybaraTabAfterFillIn < Base
        MSG = "Drop `send_keys(:tab)`: `fill_in` already blurs the field, so its save has started, and the keys race it (ObsoleteNode when the save replaces the field)."
        RESTRICT_ON_SEND = %i[send_keys].freeze

        def on_send(node)
          add_offense(node) if node.arguments.any? { |argument| argument.sym_type? && argument.value == :tab }
        end
      end
    end
  end
end
