# frozen_string_literal: true

module ERBLint
  module Linters
    # Requests use jQuery, not fetch (AGENTS.md, ESLint), in templates' inline scripts and event attributes
    class JqueryRequests < Linter
      include LinterRegistry

      # fetch( on its own, not a method like Ruby's Hash#fetch
      FETCH = /(?<![\w.$])fetch\(/

      def run(processed_source)
        processed_source.file_content.scan(FETCH) do
          range = Regexp.last_match.begin(0)...(Regexp.last_match.end(0) - 1)
          add_offense(processed_source.to_source_range(range), 'JqueryRequests: Use jQuery (`$.get`, `$.getJSON`, `$.post`, `$.ajax`) for requests, not `fetch`.')
        end
      end
    end
  end
end
