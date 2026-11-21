module RuboCop
  module Cop
    module Dandelion
      # Every route says who may use it, so none is open to anyone because its check was left out. Either with its
      # access: option (lib/route_access.rb), for levels that need no record: access: :public for anyone, which a
      # public route must say rather than get by saying nothing, access: :signed_in or access: :admin (site admins). Or,
      # for levels that need a record found first, by calling a guard from app/helpers/access_control.rb in its body
      # (event_admins_only!, membership_required!...: any *_only! or *_required!), or kick! or halt 401/403 for a
      # check of its own, or in its controller's before filter. Routes a loop defines (%w[get post].each do |verb| ...
      # send(verb, '/path')) count too.
      #
      # @example
      #   # bad
      #   get '/terms' do
      #     erb :terms
      #   end
      #   get '/e/:slug/edit' do
      #     @event = event_from_params
      #     erb :'events/build'
      #   end
      #   %w[get post].each do |verb|
      #     send(verb, '/events/:id/*') do
      #       redirect_to_slug_url(Event, '/events')
      #     end
      #   end
      #   get '/stats', access: :admins do
      #     erb :stats
      #   end
      #
      #   # good
      #   get '/terms', access: :public do
      #     erb :terms
      #   end
      #   get '/stats', provides: :json, access: :admin do
      #     erb :stats
      #   end
      #   get '/e/:slug/edit' do
      #     @event = event_from_params
      #     event_admins_only!
      #     erb :'events/build'
      #   end
      #   %w[get post].each do |verb|
      #     send(verb, '/events/:id/*', access: :public) do
      #       redirect_to_slug_url(Event, '/events')
      #     end
      #   end
      #   Dandelion::App.controller do
      #     before do
      #       sign_in_required!
      #     end
      #
      #     get '/messages' do
      #       erb :messages
      #     end
      #   end
      class RouteAccess < Base
        LEVELS = %i[public signed_in admin].freeze
        MSG = 'Say who may use this route: `access: :public`, `access: :signed_in` or `access: :admin` on it, or a guard ' \
              'like `event_admins_only!` in it once it has found the record (AGENTS.md, Conventions).'.freeze
        LEVEL_MSG = "`access:` takes one of #{LEVELS.map(&:inspect).join(', ')}.".freeze
        VERBS = %i[get post put patch delete head].to_set.freeze

        # get '/path' do, get :name, map: '/path' do, or send(verb, '/path') do inside a loop over verbs
        def_node_matcher :route_send, <<~PATTERN
          {
            (send nil? %VERBS {(str #path?) (sym _) } ...)
            (send nil? :send lvar (str #path?) ...)
          }
        PATTERN
        def_node_search :access_level, '(pair (sym :access) $_)'
        def_node_search :guard?, '{(send nil? #guard_name? ...) (send nil? :halt (int {401 403}) ...)}'
        def_node_matcher :before_filter, '(block (send nil? :before) _ $_)'
        def_node_matcher :controller?, '(block (send _ :controller ...) ...)'

        # The route blocks in a file's AST, for test/lint_test.rb to check none is missed
        def self.route_blocks(ast)
          cop = new
          ast.each_node(:block).select { |node| cop.route_send(node.send_node) }
        end

        def on_block(node)
          return unless route_send(node.send_node)

          options = node.send_node.arguments.select(&:hash_type?)
          levels = options.flat_map { |hash| access_level(hash).to_a }
          if levels.any?
            add_offense(node.send_node, message: LEVEL_MSG) unless levels.all? { |level| level.sym_type? && LEVELS.include?(level.value) }
            return
          end
          return if node.body && guard?(node.body)
          return if controller_guarded?(node)

          add_offense(node.send_node)
        end

        private

        def path?(value) = value.start_with?('/')

        def guard_name?(name) = name == :kick! || name.end_with?('_only!', '_required!')

        # A guard in the before filter of the controller the route is in
        def controller_guarded?(node)
          controller = node.each_ancestor(:block).find { |ancestor| controller?(ancestor) }
          return false unless controller&.body

          statements = controller.body.begin_type? ? controller.body.children : [controller.body]
          statements.any? { |statement| (body = before_filter(statement)) && guard?(body) }
        end
      end
    end
  end
end
