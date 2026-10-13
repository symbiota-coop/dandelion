module RuboCop
  module Cop
    module Dandelion
      # To check something isn't on the page, use `assert page.has_no_css?`: `refute page.has_css?` waits the full `default_max_wait_time` for it to appear before passing.
      #
      # @example
      #   # bad
      #   refute page.has_css?('.alert')
      #   assert !page.has_content?('Saved')
      #
      #   # good
      #   assert page.has_no_css?('.alert')
      #   assert page.has_no_content?('Saved')
      class CapybaraRefuteHas < Base
        MSG = "Use `assert %<receiver>shas_no_%<matcher>s`, which doesn't wait the full timeout first."
        RESTRICT_ON_SEND = %i[refute assert_not assert].freeze
        MATCHERS = %w[
          button checked_field content css current_path field link select selector table text title unchecked_field xpath
        ].freeze

        def on_send(node)
          check = node.first_argument
          return unless check

          if node.method?(:assert)
            return unless check.send_type? && check.method?(:!)

            check = check.receiver
          end
          return unless check&.call_type?

          matcher = check.method_name.to_s.delete_prefix('has_').delete_suffix('?')
          return unless check.method_name.to_s == "has_#{matcher}?" && MATCHERS.include?(matcher)

          receiver = check.receiver ? "#{check.receiver.source}." : ''
          add_offense(node, message: format(MSG, receiver: receiver, matcher: "#{matcher}?"))
        end
      end
    end
  end
end
