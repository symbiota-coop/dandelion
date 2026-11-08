module RuboCop
  module Cop
    module Dandelion
      # A test uses Rack (`get`, `post`, `last_response`, `sign_in_with_rack`) or the browser (`visit`, `click_on`, `page`,
      # `sign_in`), not both: Rack for a program or a forged request on the other end, the browser for a person (AGENTS.md,
      # Tests). The two don't share a session, so a test that mixes them is signed in on one and not the other. A person's
      # flow that a program's request is part of, like Stripe's webhook after a checkout, disables it there, saying so.
      #
      # @example
      #   # bad
      #   test 'cancelling' do
      #     sign_in_with_rack(account)
      #     visit "/e/#{@event.slug}"
      #   end
      #
      #   test 'refusing' do
      #     sign_in(account)
      #     click_on 'Cancel'
      #     post "/e/#{@event.slug}/cancel"
      #   end
      #
      #   # good
      #   test 'cancelling' do
      #     sign_in(account)
      #     visit "/e/#{@event.slug}"
      #     click_on 'Cancel'
      #   end
      #
      #   test 'refusing' do
      #     sign_in_with_rack(account)
      #     post "/e/#{@event.slug}/cancel"
      #     assert_equal 403, last_response.status
      #   end
      class TestOneParadigm < Base
        MSG = 'Use Rack or the browser in a test, not both: Rack for a program or a forged request, the browser for a person ' \
              '(AGENTS.md, Tests). Split it into two tests, unless a program\'s request is part of a person\'s flow.'
        RACK = %i[get post put patch delete head options sign_in_with_rack last_response last_request follow_redirect!
                  clear_cookies].freeze
        BROWSER = %i[visit sign_in page click_on click_button click_link click_link_or_button fill_in within accept_confirm
                     dismiss_confirm execute_script evaluate_script].freeze

        def on_block(node)
          return unless node.send_node.receiver.nil? && node.send_node.method?(:test)

          calls = node.each_descendant(:send).select { |call| call.receiver.nil? }
          rack = calls.find { |call| RACK.include?(call.method_name) }
          browser = calls.find { |call| BROWSER.include?(call.method_name) }
          return unless rack && browser

          add_offense([rack, browser].max_by { |call| call.source_range.begin_pos })
        end
        alias on_numblock on_block
      end
    end
  end
end
