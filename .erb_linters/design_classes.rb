# frozen_string_literal: true

module ERBLint
  module Linters
    # Rules from the Design section of AGENTS.md that a template's classes and inline scripts can break
    class DesignClasses < Linter
      include LinterRegistry

      BOOTSTRAP_COLOURS = 'primary|secondary|success|danger|warning|info|light|dark'

      PATTERNS = {
        # Success is the theme colour
        /(?<![\w-])[a-z][a-z-]*-success(?![\w-])/ => 'Success is the theme colour, so use `-primary`, not `-success`.',
        # Bootstrap 5 dropped the badge colour classes
        /(?<![\w-])badge-(?:#{BOOTSTRAP_COLOURS})(?![\w-])/o => 'Badges are `badge text-bg-*`; there is no `badge-*` colour class.',
        # Bootstrap's d-* classes are !important, so .show() can't undo them
        /\b(?:(?:add|remove|toggle)Class|classList\.(?:add|remove|toggle))\(\s*(['"])d-none\1/ =>
          'To show and hide elements from JS, start them hidden with `style="display: none"` and use `.show()` / `.hide()` / `.toggle()`, not `d-none`.'
      }.freeze

      # class="..." attributes and class: '...' options in Ruby
      CLASS_LISTS = /\bclass(?:=|:\s*)(['"])(.*?)\1/m

      def run(processed_source)
        source = processed_source.file_content

        PATTERNS.each do |pattern, message|
          source.scan(pattern) { add(processed_source, Regexp.last_match.begin(0)...Regexp.last_match.end(0), message) }
        end

        source.scan(CLASS_LISTS) do
          match = Regexp.last_match
          classes = match[2].gsub(/<%.*?%>/m) { |erb| ' ' * erb.length } # Ruby inside the attribute isn't a class
          classes.to_enum(:scan, /(?<![\w-])label(?![\w-])/).each do
            start = match.begin(2) + Regexp.last_match.begin(0)
            add(processed_source, start...(start + 5), 'There is no `.label` class; use `badge text-bg-*`.')
          end
        end
      end

      private

      def add(processed_source, range, message)
        add_offense(processed_source.to_source_range(range), "DesignClasses: #{message}")
      end
    end
  end
end
