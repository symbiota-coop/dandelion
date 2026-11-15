module RuboCop
  module Cop
    module Dandelion
      # Show plain text someone typed with `plain_text_html(text)`, not by escaping it and adding `<br>`s yourself, so
      # it's escaped the same way everywhere (with `links: false` where its URLs and emails shouldn't be links).
      # `lib/mail/email_helper.rb`'s `nl2br` is the emails' own, as email templates don't have the app's helpers.
      #
      # @example
      #   # bad
      #   ERB::Util.html_escape(testimonial).gsub("\n", '<br>')
      #   h(message).gsub("\n", '<br />').html_safe
      #
      #   # good
      #   plain_text_html(testimonial, links: false)
      #   plain_text_html(message)
      class EscapedLineBreaks < Base
        MSG = 'Show plain text with `plain_text_html(text)` (or `links: false`), not escaped with `<br>`s added by hand.'
        RESTRICT_ON_SEND = %i[gsub].freeze

        # h(...), html_escape(...) or ERB::Util.h / html_escape(...), then .gsub("\n", '<br...>')
        def_node_matcher :escaped_line_breaks?, <<~PATTERN
          (send (send {nil? (const (const {nil? cbase} :ERB) :Util)} {:h :html_escape} ...) :gsub (str #newline?) (str #line_break?))
        PATTERN

        def on_send(node)
          add_offense(node) if escaped_line_breaks?(node)
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
