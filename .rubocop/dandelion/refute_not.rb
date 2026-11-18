module RuboCop
  module Cop
    module Dandelion
      # To check something is false, use Minitest's `refute`, as most of the tests do, rather than ActiveSupport's
      # `assert_not` or `assert !`, which mean the same: one way to write it. A double negative (`assert !!x`) is `assert x`.
      #
      # @example
      #   # bad
      #   assert_not event.valid?
      #   assert !event.valid?, 'Should be refused'
      #   assert !!event.valid?
      #
      #   # good
      #   refute event.valid?
      #   refute event.valid?, 'Should be refused'
      #   assert event.valid?
      #   assert_equal false, event.valid?
      class RefuteNot < Base
        extend AutoCorrector

        MSG = 'Use `%<assertion>s %<check>s`.'
        RESTRICT_ON_SEND = %i[assert assert_not].freeze

        def on_send(node)
          check = node.first_argument
          return unless check

          negations = node.method?(:assert_not) ? 1 : 0
          while negation?(unwrapped(check))
            check = unwrapped(check).receiver
            negations += 1
          end
          return if negations.zero?

          # assert !(a && b) is refute a && b: the parentheses only grouped what ! negated
          check = unwrapped(check)
          assertion = negations.odd? ? 'refute' : 'assert'
          add_offense(node, message: format(MSG, assertion: assertion, check: check.source)) do |corrector|
            corrector.replace(node.loc.selector, assertion)
            corrector.replace(node.first_argument, check.source)
          end
        end

        private

        def unwrapped(check)
          check = check.children.first while check.begin_type? && check.children.one?
          check
        end

        def negation?(check)
          check.send_type? && check.method?(:!) && (check.prefix_bang? || check.prefix_not?)
        end
      end
    end
  end
end
