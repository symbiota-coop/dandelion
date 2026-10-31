# frozen_string_literal: true

module ERBLint
  module Linters
    # ErbSafety, with two changes:
    # - It leaves out better_html's script type check, whose list of types is fixed: the AllowedScriptType linter checks
    #   script types against our own list instead
    # - It checks every script's content. better_html finds the content after a <script> tag with find_index, which
    #   compares AST nodes by structure, so a tag the same as an earlier one (every bare <script>) got the first one's
    #   content, and the scripts after it went unchecked
    class SafeErb < ErbSafety
      include LinterRegistry

      self.config_schema = ErbSafety::ConfigSchema

      # Finds each tag's content by identity rather than ==
      module ScriptTagsByIdentity
        def script_tags
          nodes = ast.to_a
          Enumerator.new do |yielder|
            @parser.nodes_with_type(:tag).each do |tag_node|
              tag = BetterHtml::Tree::Tag.from_node(tag_node)
              next if tag.closing? || tag.name != 'script'

              index = nodes.index { |node| node.equal?(tag_node) }
              next_node = nodes[index + 1]
              yielder.yield(tag, next_node&.type == :text ? next_node : nil)
            end
          end
        end
      end
      BetterHtml::TestHelper::SafeErb::Base.prepend(ScriptTagsByIdentity)

      private

      def tester_classes
        super - [BetterHtml::TestHelper::SafeErb::AllowedScriptType]
      end
    end
  end
end
