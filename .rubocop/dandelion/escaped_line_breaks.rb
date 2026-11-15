module RuboCop
  module Cop
    module Dandelion
      # Show plain text someone typed with `plain_text_html(text)`, not by escaping it and adding `<br>`s yourself, so
      # it's escaped the same way everywhere (with `links: false` where its URLs and emails shouldn't be links). Nor by
      # adding `<br>`s and links to it unescaped and sanitising it as HTML (`Rinku.auto_link(text.gsub("\n", '<br />'))`,
      # with or without `Sanitize.fragment`), which renders markup someone typed rather than showing it as typed.
      # `lib/mail/email_helper.rb`'s `nl2br` is the emails' own, as email templates don't have the app's helpers.
      #
      # @example
      #   # bad
      #   ERB::Util.html_escape(testimonial).gsub("\n", '<br>')
      #   h(message).gsub("\n", '<br />').html_safe
      #   Sanitize.fragment(Rinku.auto_link(answer.gsub("\n", '<br />')), Sanitize::Config::DANDELION)
      #   Rinku.auto_link(reason.gsub("\n", '<br>'))
      #
      #   # good
      #   plain_text_html(testimonial, links: false)
      #   plain_text_html(message)
      #   plain_text_html(answer)
      #   Sanitize.fragment(Rinku.auto_link(intro), Sanitize::Config::DANDELION)
      class EscapedLineBreaks < Base
        MSG = 'Show plain text with `plain_text_html(text)` (or `links: false`), not escaped or sanitised with `<br>`s added by hand.'
        RESTRICT_ON_SEND = %i[gsub auto_link].freeze

        # h(...), html_escape(...) or ERB::Util.h / html_escape(...), then .gsub("\n", '<br...>')
        def_node_matcher :escaped_line_breaks?, <<~PATTERN
          (send (send {nil? (const (const {nil? cbase} :ERB) :Util)} {:h :html_escape} ...) :gsub (str #newline?) (str #line_break?))
        PATTERN

        # Rinku.auto_link(text.gsub("\n", '<br...>'), ...)
        def_node_matcher :linked_line_breaks?, <<~PATTERN
          (send (const {nil? cbase} :Rinku) :auto_link (send _ :gsub (str #newline?) (str #line_break?)) ...)
        PATTERN

        def on_send(node)
          add_offense(node) if escaped_line_breaks?(node) || linked_line_breaks?(node)
        end

        private

        def newline?(string)
          string == "\n"
        end

        def line_break?(replacement)
          replacement.start_with?('<br')
        end
      end
    end
  end
end
