# frozen_string_literal: true

module ERBLint
  module Linters
    # Links that POST, destroy links among them, carry data-method="post": app.js and pagelets.js send no other
    # link as a POST, so that a link in user content, which keeps relative hrefs but loses data-* attributes, can't make
    # whoever clicks it delete something. confirm.js also asks before a destroy link only when it has it. In a dropdown_nav
    # item it's { 'data-method' => 'post' }, and the form builder's submit_block adds it to its destroy_url. Checks <a> tags
    # and dropdown_nav items whose path ends in destroy
    class PostLinks < Linter
      include LinterRegistry

      MESSAGE = 'PostLinks: A destroy link is sent as a POST only with `data-method="post"` ' \
                "(`{ 'data-method' => 'post' }` in a dropdown_nav item), which user content can't carry: add it."

      # <a> tags, whose quoted attributes may hold ERB
      LINKS = /<a\b(?:[^>"']|"[^"]*"|'[^']*')*>/m
      HREF = /\shref=(["'])(.*?)\1/m
      # dropdown_nav items with a destroy path and no attributes: ['Remove order', "/orders/#{id}/destroy"]
      DROPDOWN_ITEMS = /\[\s*(['"])(?:(?!\1).)*\1,\s*(['"])[^'"]*destroy(?:\?[^'"]*)?\2\s*\]/

      def run(processed_source)
        source = processed_source.file_content

        source.scan(LINKS) do
          match = Regexp.last_match
          tag = match[0]
          next unless (href = tag[HREF, 2])
          next if tag.match?(/\sdata-method=(["'])post\1/)

          path = href.gsub(/<%.*?%>/m, 'x').split('?').first
          add(processed_source, match) if path.end_with?('destroy')
        end

        source.scan(DROPDOWN_ITEMS) { add(processed_source, Regexp.last_match) }
      end

      private

      def add(processed_source, match)
        add_offense(processed_source.to_source_range(match.begin(0)...match.end(0)), MESSAGE)
      end
    end
  end
end
