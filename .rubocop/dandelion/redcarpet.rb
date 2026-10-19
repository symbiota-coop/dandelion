module RuboCop
  module Cop
    module Dandelion
      # Render markdown with `md(text)` or `MarkdownRenderer.render`, not a Redcarpet of your own, so it renders the same
      # everywhere and untrusted text is sanitized. `lib/markdown_renderer.rb` is the one place that uses Redcarpet.
      #
      # @example
      #   # bad
      #   Redcarpet::Markdown.new(Redcarpet::Render::HTML).render(text)
      #
      #   # good
      #   MarkdownRenderer.render(text, hard_wrap: true)
      class Redcarpet < Base
        MSG = 'Render markdown with `md(text)` or `MarkdownRenderer.render`, not Redcarpet directly.'

        def_node_matcher :redcarpet?, '(const {nil? cbase} :Redcarpet)'

        def on_const(node)
          return unless redcarpet?(node)

          add_offense(node)
        end
      end
    end
  end
end
