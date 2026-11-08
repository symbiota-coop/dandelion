module RuboCop
  module Cop
    module Dandelion
      # A test file includes Rack::Test::Methods only if a test uses Rack, and Capybara::DSL only if one uses the browser,
      # so what a file includes says how its tests reach the app (AGENTS.md, Tests). The calls are TestOneParadigm's.
      #
      # @example
      #   # bad
      #   class CalendarTest < ActiveSupport::TestCase
      #     include Capybara::DSL
      #     include Rack::Test::Methods
      #     test 'the feed' do
      #       get '/events.ics'
      #     end
      #   end
      #
      #   # good
      #   class CalendarTest < ActiveSupport::TestCase
      #     include Rack::Test::Methods
      #     test 'the feed' do
      #       get '/events.ics'
      #     end
      #   end
      class TestUnusedParadigm < Base
        MSG = '%<mixin>s is included but no test uses it: remove the include.'
        MIXINS = { 'Rack::Test::Methods' => TestOneParadigm::RACK, 'Capybara::DSL' => TestOneParadigm::BROWSER }.freeze

        def on_class(node)
          calls = node.each_descendant(:send).select { |call| call.receiver.nil? }.map(&:method_name)
          node.each_descendant(:send).each do |call|
            next unless call.receiver.nil? && call.method?(:include) && call.first_argument&.const_type?

            used = MIXINS[call.first_argument.const_name]
            add_offense(call, message: format(MSG, mixin: call.first_argument.const_name)) if used && (calls & used).empty?
          end
        end
      end
    end
  end
end
