module RuboCop
  module Cop
    module Dandelion
      # Every /g/:slug route says who may use it, with one of the gathering checks in access_control.rb (or a 403 of its
      # own), so a new route can't be left open to anyone by leaving its check out. A route that only redirects needs
      # none. A public one (the gathering's page, joining, applying, a webhook) disables the cop, saying why.
      #
      # @example
      #   # bad
      #   get '/g/:slug/rotas' do
      #     @gathering = gathering_from_params
      #     erb :'rotas/rotas'
      #   end
      #
      #   # good
      #   get '/g/:slug/rotas' do
      #     @gathering = gathering_from_params
      #     confirmed_membership_required!
      #     erb :'rotas/rotas'
      #   end
      #   post '/g/:slug/shifts/:id/destroy' do
      #     @gathering = gathering_from_params
      #     @shift = @gathering.shifts.find(params[:id]) || not_found
      #     own_or_gathering_admins_only!(@shift)
      #     @shift.destroy
      #   end
      #   get '/g/:slug/tiers' do
      #     redirect "/g/#{params[:slug]}/options"
      #   end
      class GatheringPermission < Base
        MSG = 'Say who may use this gathering route: `confirmed_membership_required!`, `membership_required!`, ' \
              '`gathering_admins_only!`, `own_or_gathering_admins_only!` or `halt 403` (or, for a public page, disable this, saying why).'.freeze
        CHECKS = %i[confirmed_membership_required! membership_required! gathering_admins_only! own_or_gathering_admins_only!].to_set.freeze
        VERBS = %i[get post put patch delete].to_set.freeze

        def_node_matcher :route, '(block (send nil? %VERBS (str $_) ...) _ $_)'
        def_node_search :check?, '{(send nil? %CHECKS ...) (send nil? :halt (int 403) ...)}'
        def_node_matcher :redirect_only?, '(send nil? :redirect ...)'

        def on_block(node)
          route(node) do |path, body|
            next unless path.start_with?('/g/:slug')
            next if body && (check?(body) || redirect_only?(body))

            add_offense(node.send_node)
          end
        end
      end
    end
  end
end
