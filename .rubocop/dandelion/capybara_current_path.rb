module RuboCop
  module Cop
    module Dandelion
      # Check the page's path with `has_current_path?`, which waits for the page: `current_path` and `current_url` don't, so
      # straight after a click they can still be the old page's. Reading them in a failure message is fine.
      #
      # @example
      #   # bad
      #   assert_equal '/events', current_path
      #
      #   assert page.current_url.include?('added=true')
      #
      #   # good
      #   assert page.has_current_path?('/events', ignore_query: true)
      #   assert page.has_current_path?(/added=true/, url: true), "Got #{page.current_url}"
      class CapybaraCurrentPath < Base
        MSG = 'Use `has_current_path?`, which waits for the page; `%<method>s` can still be the old page.'
        RESTRICT_ON_SEND = %i[current_path current_url].freeze

        def on_send(node)
          return unless node.receiver.nil? || (node.receiver.send_type? && node.receiver.method?(:page) && node.receiver.receiver.nil?)
          return if node.each_ancestor(:dstr).any?

          add_offense(node, message: format(MSG, method: node.method_name))
        end
      end
    end
  end
end
