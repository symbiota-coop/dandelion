module RuboCop
  module Cop
    module Dandelion
      # A concern includes our other concerns (models/concerns) at module level, as dependencies, not inside `included do`.
      # ActiveSupport::Concern includes its dependencies in the model first, then extends it with this concern's
      # `class_methods`, then runs `included`; so a concern included inside `included do` comes after, and its class
      # methods override this one's (Searchable's `search_fields`, which raises, hid Subgroup's). Modules that aren't our
      # concerns, like Geocoder::Model::Mongoid, still go inside `included do`, so they're included in the model itself.
      #
      # @example
      #   # bad
      #   module EventFields
      #     extend ActiveSupport::Concern
      #     included do
      #       include EmailFields
      #     end
      #   end
      #
      #   # good
      #   module EventFields
      #     extend ActiveSupport::Concern
      #     include EmailFields
      #     included do
      #       include Geocoder::Model::Mongoid
      #     end
      #   end
      class ConcernInclude < Base
        MSG = 'Include `%<name>s` at module level, not inside `included do`, so its class methods come before this concern\'s.'
        CONCERNS_DIR = File.expand_path('../../models/concerns', __dir__)

        def on_send(node)
          return unless node.receiver.nil? && node.method?(:include)

          block = node.each_ancestor(:block).first
          return unless block && block.send_node.receiver.nil? && block.send_node.method?(:included) && !block.send_node.arguments?

          node.arguments.each do |argument|
            next unless argument.const_type? && argument.namespace.nil? && concern?(argument.short_name.to_s)

            add_offense(argument, message: format(MSG, name: argument.short_name))
          end
        end

        private

        def concern?(name)
          File.exist?(File.join(CONCERNS_DIR, "#{name.gsub(/(?<!^)([A-Z])/, '_\1').downcase}.rb"))
        end
      end
    end
  end
end
