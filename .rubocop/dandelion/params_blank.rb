module RuboCop
  module Cop
    module Dandelion
      # `blanks_to_nils!` (lib/param_helpers.rb) makes blank params nil, so check `params[:x]`, not `.present?` or `.blank?`.
      #
      # @example
      #   # bad
      #   if params[:q].present?
      #   if params[:q].blank?
      #   if params.dig(:event, :name).present?
      #
      #   # good
      #   if params[:q]
      #   unless params[:q]
      class ParamsBlank < Base
        MSG = 'Blank params are already nil, so check `params[...]` itself, not `.%<method>s`.'
        RESTRICT_ON_SEND = %i[present? blank?].freeze

        def on_send(node)
          receiver = node.receiver
          receiver = receiver.receiver while receiver&.call_type? && (receiver.method?(:[]) || receiver.method?(:dig))
          return unless receiver&.send_type? && receiver.receiver.nil? && receiver.method?(:params) && !receiver.arguments?

          add_offense(node.loc.selector, message: format(MSG, method: node.method_name))
        end
        alias on_csend on_send
      end
    end
  end
end
