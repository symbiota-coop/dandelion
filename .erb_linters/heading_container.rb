# frozen_string_literal: true

module ERBLint
  module Linters
    # A page heading straight above a .container: the heading sits at the content's left edge, while .container centres
    # what's below it at a max width of its own, so the form under the heading starts further in and they don't line up
    # (rotas' and timetables' build pages did this). #content already pads the page, so content needs no .container
    class HeadingContainer < Linter
      include LinterRegistry

      MESSAGE = 'HeadingContainer: A heading over a `.container` sits at the left while the container centres what follows ' \
                "at its own width, so they don't line up. Drop the `.container`: #content already pads the page."

      # A heading, then only whitespace or ERB comments, then a div whose classes include container. Each comment runs to
      # its first %>, rather than .*?, which could also run across several and backtrack exponentially
      HEADING_THEN_CONTAINER = %r{</h[1-6]>(?:\s|<%#(?:[^%]|%(?!>))*%>)*<div\b[^>]*\sclass=(["'])(?:[^"']*\s)?container(?:\s[^"']*)?\1}m

      def run(processed_source)
        processed_source.file_content.scan(HEADING_THEN_CONTAINER) do
          match = Regexp.last_match
          add_offense(processed_source.to_source_range(match.begin(0)...match.end(0)), MESSAGE)
        end
      end
    end
  end
end
