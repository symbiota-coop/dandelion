module RuboCop
  module Cop
    module Dandelion
      # Straight after a click, assert something on the new page before checking something isn't there: until the new page
      # loads, a `has_no_` check passes on the old one. A click whose confirm is dismissed doesn't leave the page.
      #
      # @example
      #   # bad
      #   click_button 'Delete'
      #   assert page.has_no_content?('Draft')
      #
      #   click_link 'Next'
      #   assert_no_selector '.draft'
      #
      #   # good
      #   click_button 'Delete'
      #   assert page.has_content?('Deleted')
      #   assert page.has_no_content?('Draft')
      #   dismiss_confirm { click_button 'Delete' }
      #   assert page.has_no_content?('Deleted')
      class CapybaraHasNoAfterClick < Base
        MSG = "Assert something on the new page first: straight after a click, this can pass on the old page."
        CLICKS = %i[click_button click_link click_on click_link_or_button click].freeze
        DISMISSALS = %i[dismiss_confirm dismiss_prompt].freeze

        def on_begin(node)
          node.children.each_cons(2) do |previous, statement|
            add_offense(statement) if clicks?(previous) && absence_check?(statement)
          end
        end
        alias on_kwbegin on_begin

        private

        def clicks?(node)
          return false unless node.is_a?(AST::Node)

          [node, *node.each_descendant(:send, :csend)].any? do |call|
            call.call_type? && CLICKS.include?(call.method_name) &&
              call.each_ancestor(:block).none? { |block| DISMISSALS.include?(block.method_name) }
          end
        end

        # assert page.has_no_css?(...) and Capybara's assert_no_selector, assert_no_text...
        def absence_check?(node)
          return false unless node.is_a?(AST::Node) && node.send_type?
          return true if node.method_name.start_with?('assert_no_')

          check = node.first_argument
          node.method?(:assert) && check&.call_type? && check.method_name.start_with?('has_no_')
        end
      end
    end
  end
end
