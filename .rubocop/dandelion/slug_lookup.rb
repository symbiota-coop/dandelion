module RuboCop
  module Cop
    module Dandelion
      # URLs name organisations, gatherings, events, activities and local groups by slug, and accounts by username:
      # find them with the `*_from_params` helpers (app/helpers/helpers.rb), which 404 when there's none, or with
      # `find_by_slug_or_id`, which also takes the id in older links. Ids from forms and query strings
      # (`params[:organisation_id]`) are fine. A route for an old URL that named one by id (/events/:id/...) redirects
      # with `redirect_to_slug_url`, which finds it by that id itself.
      #
      # @example
      #   # bad
      #   @event = Event.find(params[:id])
      #   @organisation = Organisation.find_by(slug: params[:slug])
      #   @account = Account.unscoped.find_by(username: params[:username])
      #   @event = Event.find_by_slug_or_id(slug: params[:slug]) || not_found
      #   @gathering = gathering_from_params || not_found
      #
      #   # good
      #   @event = event_from_params
      #   @event = event_from_params(Event.unscoped)
      #   @activity = activity_from_params
      #   @organisation = Organisation.find(params[:organisation_id])
      #   cohost = Organisation.find_by_slug_or_id(slug: params[:cohost])
      #   redirect_to_slug_url(Event.unscoped, '/events') { |event| "/e/#{event.slug}" }
      class SlugLookup < Base
        MSG = 'Find %<model>s from a URL with `find_by_slug_or_id` (or redirect an old id URL with `redirect_to_slug_url`).'
        HELPER_MSG = 'Find %<model>s from the URL with `%<helper>s`, which 404s when there is none.'
        REDUNDANT_MSG = '`%<helper>s` already 404s when there is none: drop `|| not_found`.'
        MODELS = %w[Event Organisation Gathering Activity LocalGroup Account].freeze
        # The models a helper finds from the URL, and the param it reads
        HELPERS = {
          'Event' => ['event_from_params', %i[slug event_slug]], 'Organisation' => ['organisation_from_params', %i[slug organisation_slug]],
          'Gathering' => ['gathering_from_params', %i[slug]], 'Account' => ['account_from_params', %i[username]]
        }.freeze
        RESTRICT_ON_SEND = %i[find find_by].freeze

        # params[:id] and the other keys routes name records by
        def_node_matcher :url_param?, '(send (send nil? :params) :[] (sym {:id :slug :username :organisation_slug :event_slug}))'

        # find_by(slug: params[...]) or find_by(username: params[...])
        def_node_matcher :find_by_slug_param?, '(send _ :find_by (hash <(pair (sym {:slug :username}) (send (send nil? :params) :[] _)) ...>))'

        # Model.find_by_slug_or_id(slug: params[:key]) || not_found
        def_node_matcher :slug_lookup_or_not_found, <<~PATTERN
          (or (send (const nil? $_) :find_by_slug_or_id (hash (pair (sym :slug) (send (send nil? :params) :[] (sym $_))))) (send nil? :not_found))
        PATTERN

        # event_from_params || not_found
        def_node_matcher :helper_or_not_found, '(or (send nil? $_ ...) (send nil? :not_found))'

        def on_send(node)
          model = model_name(node)
          return unless MODELS.include?(model)
          return unless node.method?(:find_by) ? find_by_slug_param?(node) : node.arguments.one? && url_param?(node.first_argument)

          add_offense(node.loc.selector, message: format(MSG, model: model))
        end
        alias on_csend on_send

        def on_or(node)
          slug_lookup_or_not_found(node) do |model, key|
            helper, keys = HELPERS[model.to_s]
            add_offense(node, message: format(HELPER_MSG, model: model, helper: helper)) if keys&.include?(key)
          end
          helper_or_not_found(node) do |helper|
            add_offense(node, message: format(REDUNDANT_MSG, helper: helper)) if helper.end_with?('_from_params')
          end
        end

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
