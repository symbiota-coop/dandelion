module RuboCop
  module Cop
    module Dandelion
      # URLs name organisations, gatherings, events, activities and local groups by slug, and accounts by username:
      # find them with `find_by_slug_or_id`, which also takes the id in older links. Ids from forms and query strings
      # (`params[:organisation_id]`) are fine.
      #
      # @example
      #   # bad
      #   @event = Event.find(params[:id])
      #   @organisation = Organisation.find_by(slug: params[:slug])
      #   @account = Account.unscoped.find_by(username: params[:username])
      #
      #   # good
      #   @event = Event.find_by_slug_or_id(slug: params[:slug])
      #   @activity = activity_from_params
      #   @organisation = Organisation.find(params[:organisation_id])
      class SlugLookup < Base
        MSG = 'Find %<model>s from a URL with `find_by_slug_or_id`.'
        MODELS = %w[Event Organisation Gathering Activity LocalGroup Account].freeze
        RESTRICT_ON_SEND = %i[find find_by].freeze

        # params[:id] and the other keys routes name records by
        def_node_matcher :url_param?, '(send (send nil? :params) :[] (sym {:id :slug :username :organisation_slug :event_slug}))'

        # find_by(slug: params[...]) or find_by(username: params[...])
        def_node_matcher :find_by_slug_param?, '(send _ :find_by (hash <(pair (sym {:slug :username}) (send (send nil? :params) :[] _)) ...>))'

        def on_send(node)
          model = model_name(node)
          return unless MODELS.include?(model)
          return unless node.method?(:find_by) ? find_by_slug_param?(node) : node.arguments.one? && url_param?(node.first_argument)

          add_offense(node.loc.selector, message: format(MSG, model: model))
        end
        alias on_csend on_send

        private

        # The class a chain of calls starts from (Event in Event.unscoped.find)
        def model_name(node)
          receiver = node.receiver
          receiver = receiver.receiver while receiver&.call_type?
          receiver.const_name if receiver&.const_type?
        end
      end
    end
  end
end
