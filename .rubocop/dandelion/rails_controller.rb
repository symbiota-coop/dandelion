module RuboCop
  module Cop
    module Dandelion
      # Controllers are `Dandelion::App.controller` blocks (Padrino), not Rails controllers: no `before_action`, `render`,
      # `redirect_to`, `respond_to` or strong parameters.
      #
      # @example
      #   # bad
      #   before_action :sign_in_required!
      #   render :show
      #   redirect_to '/events'
      #   respond_to { |format| format.json { event.to_json } }
      #   params.require(:event).permit(:name)
      #
      #   # good
      #   before { sign_in_required! }
      #   erb :'events/show'
      #   redirect '/events'
      #   content_type == :json ? event.to_json : erb(:'events/show')
      #   Event.new(mass_assigning(params[:event], Event))
      class RailsController < Base
        MESSAGES = {
          before: 'Padrino has `before do ... end` (optionally for some routes), not `%<method>s`.',
          render: 'Use `erb`, `partial` or `cp`, not `render`.',
          redirect_to: 'Use `redirect`, not `redirect_to`.',
          respond_to: 'Padrino routes take `provides:` and branch on `content_type`, not `respond_to`.',
          strong_params: 'Padrino has no strong parameters: pass `params[:x]` through `mass_assigning(params[:x], Model)`, ' \
                         'which keeps to the fields the model allows.'
        }.freeze
        CALLBACKS = %i[before_action after_action around_action skip_before_action skip_after_action before_filter after_filter].freeze
        RESTRICT_ON_SEND = (CALLBACKS + %i[render redirect_to respond_to require permit]).freeze

        def_node_matcher :params?, '(send nil? :params)'

        def on_send(node)
          if %i[require permit].include?(node.method_name)
            return unless params?(params_root(node.receiver))

            add_offense(node.loc.selector, message: MESSAGES[:strong_params])
          elsif node.receiver.nil?
            key = CALLBACKS.include?(node.method_name) ? :before : node.method_name
            add_offense(node.loc.selector, message: format(MESSAGES[key], method: node.method_name))
          end
        end

        private

        # params, from params.require(:x) or params[:x] before the call
        def params_root(node)
          node = node.receiver while node&.call_type? && !params?(node)
          node
        end
      end
    end
  end
end
