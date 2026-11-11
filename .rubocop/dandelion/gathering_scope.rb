module RuboCop
  module Cop
    module Dandelion
      # A gathering's records (its rotas, shifts, teams, options...) are found through the gathering, from a URL under
      # /g/:slug, so the permission check for the gathering covers everything a route touches. Found by id alone, a
      # route can check one gathering and read another's records, as /rota/rslot/role/... once did with a slot and role
      # from another gathering's rota.
      #
      # @example
      #   # bad
      #   @rota = Rota.find(params[:id])
      #   @shift = Shift.find_by(id: params[:shift_id])
      #
      #   # good
      #   @rota = @gathering.rotas.find(params[:id])
      #   @role = @rota.roles.find(params[:role_id])
      #   @shift = @gathering.shifts.find_by(id: params[:shift_id])
      class GatheringScope < Base
        MSG = "Find a gathering's %<model>s through the gathering, under /g/:slug (`@gathering.%<association>s.find(...)`).".freeze
        # The models that belong to a gathering: test/lint_test.rb checks it against the models themselves
        MODELS = %w[
          Attendance InventoryItem Mapplication Membership Option Optionship Payment Role Rota Rslot Shift Space Spend
          Tactivity Team Teamship Timetable Tslot Verdict
        ].freeze
        RESTRICT_ON_SEND = %i[find find_by].freeze

        def_node_search :params?, '(send nil? :params)'

        def on_send(node)
          receiver = node.receiver
          return unless receiver&.const_type? && MODELS.include?(receiver.const_name)
          return unless node.arguments.any? { |argument| params?(argument) }

          add_offense(node.loc.selector, message: format(MSG, model: receiver.const_name, association: association(receiver.const_name)))
        end
        alias on_csend on_send

        private

        def association(model)
          snake = model.gsub(/(?<!^)([A-Z])/, '_\1').downcase
          snake.end_with?('y') ? "#{snake.delete_suffix('y')}ies" : "#{snake}s"
        end
      end
    end
  end
end
