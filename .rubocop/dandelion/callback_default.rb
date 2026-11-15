module RuboCop
  module Cop
    module Dandelion
      # Give a field a constant default with `default:` on its `field`, not by filling it in when it's nil in a callback.
      # `default:` is set when a record is built or loaded without the field. A callback that fills it in every save is
      # only for a field a form can blank (a blank Integer field casts to nil), so that blank means the default: say so
      # in a disable. A default that depends on other fields (`self.currency ||= default_currency`) isn't constant, so
      # isn't flagged.
      #
      # @example
      #   # bad
      #   self.balance = 0 if balance.nil?
      #   self.worth = 1 unless worth
      #   self.paid = 0 if paid_before_type_cast.nil?
      #   self.subject ||= 'Discussion'
      #
      #   # good
      #   field :balance, type: Float, default: 0
      #   self.currency ||= default_currency
      #   self.name = name.downcase if name
      #   self.desired_threshold = 0 if desired_threshold && (desired_threshold < 0)
      class CallbackDefault < Base
        MSG = 'Give a constant default with `default:` on the field. Fill it in a callback only when a form can blank the field, with a disable saying so.'

        # self.x ||= literal, unless it hangs on another condition (`if commentable_type == "Event"`)
        def on_or_asgn(node)
          target, value = *node
          return unless target.send_type? && target.receiver&.self_type? && constant?(value) && !node.parent&.if_type?

          add_offense(node)
        end

        # self.x = literal, when x is nil (x.nil?, x_before_type_cast.nil?, !x, x.blank?, or unless x)
        def on_send(node)
          return unless node.setter_method? && node.receiver&.self_type? && node.arguments.one? && constant?(node.first_argument)

          parent = node.parent
          return unless parent&.if_type? && !parent.elsif? && parent.branches.compact.one?

          field = node.method_name.to_s.delete_suffix('=').to_sym
          add_offense(parent) if nil_check?(parent.condition, field, negated: parent.unless? ^ parent.else_branch.equal?(node))
        end

        private

        def constant?(value)
          !value.nil_type? && (value.literal? && value.recursive_basic_literal?)
        end

        # Whether the condition holds when the field is nil, or, negated (unless, else), fails when it is
        def nil_check?(condition, field, negated:)
          return field_read?(condition, field) if negated

          condition.send_type? && %i[nil? blank? !].include?(condition.method_name) && field_read?(condition.receiver, field)
        end

        def field_read?(node, field)
          node&.send_type? && node.receiver.nil? && node.arguments.none? &&
            [field, :"#{field}_before_type_cast"].include?(node.method_name)
        end
      end
    end
  end
end
