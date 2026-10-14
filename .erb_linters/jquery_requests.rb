# frozen_string_literal: true

module ERBLint
  module Linters
    # Requests use jQuery, not fetch (AGENTS.md), in the JavaScript in a template's Ruby (onclick: '...'). ESLint checks the
    # template's own scripts and event attributes (eslint.config.mjs)
    class JqueryRequests < Linter
      include LinterRegistry

      # fetch( on its own, not a method like Ruby's Hash#fetch
      FETCH = /(?<![\w.$])fetch\(/
      ERB_TAGS = /<%(?!#).*?%>/m

      def run(processed_source)
        processed_source.file_content.scan(ERB_TAGS) do
          tag = Regexp.last_match
          tag[0].scan(FETCH) do
            range = (tag.begin(0) + Regexp.last_match.begin(0))...(tag.begin(0) + Regexp.last_match.end(0) - 1)
            add_offense(processed_source.to_source_range(range), 'JqueryRequests: Use jQuery (`$.get`, `$.getJSON`, `$.post`, `$.ajax`) for requests, not `fetch`.')
          end
        end
      end
    end
  end
end
