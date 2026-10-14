module RuboCop
  module Cop
    module Dandelion
      # In a test, `@` variables come from helpers (`create_event`, file-local setup methods): anything created inline is a
      # local. A test may refresh a variable a helper in its file sets.
      #
      # @example
      #   # bad
      #   test 'cancelling' do
      #     @order = create_order
      #   end
      #
      #   # good
      #   test 'cancelling' do
      #     order = create_order
      #     @event = Event.find(@event.id)
      #   end
      #
      #   def setup_event
      #     @event = create_event
      #   end
      class TestInstanceVariable < Base
        MSG = 'Use a local: `@` variables in tests come from helpers.'

        def on_block(node)
          return unless node.send_node.receiver.nil? && node.send_node.method?(:test)

          node.each_descendant(:ivasgn) do |assignment|
            add_offense(assignment.loc.name) unless helper_variables.include?(assignment.name)
          end
        end
        alias on_numblock on_block

        private

        # The variables the file's own helper methods set
        def helper_variables
          @helper_variables ||= processed_source.ast.each_node(:def, :defs).flat_map { |method| method.each_descendant(:ivasgn).map(&:name) }
        end
      end
    end
  end
end
