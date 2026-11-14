module RuboCop
  module Cop
    module Dandelion
      # `assert record.reload` can't fail: with `Mongoid.raise_not_found_error = false` (config/boot.rb), `reload` returns
      # the document even when it's been deleted. To check it still exists, find it again.
      #
      # @example
      #   # bad
      #   assert organisationship.reload
      #   assert(@event.reload)
      #
      #   # good
      #   assert Organisationship.find(organisationship.id)
      #   assert organisationship.reload.admin?
      #   refute organisationship.reload.unsubscribed
      class AssertReload < Base
        MSG = "`reload` returns the document even when it's been deleted (raise_not_found_error is false), so this can't " \
              'fail: use `assert Model.find(id)` to check it still exists.'
        RESTRICT_ON_SEND = %i[assert].freeze

        def on_send(node)
          check = node.first_argument
          return unless check&.call_type? && check.method?(:reload) && !check.arguments? && check.receiver

          add_offense(node)
        end
      end
    end
  end
end
