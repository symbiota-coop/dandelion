# frozen_string_literal: true

require 'json'

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
      # <select> tags and select_tag calls, which take form-select
      SELECTS = /<select\b(?:[^>"']|"[^"]*"|'[^']*')*>|\bselect_tag\b.*?%>/m
      FORM_SELECT = /(?<![\w-])form-select(?![\w-])/
      # Classes added from inline scripts
      CLASS_CALLS = /\b(?:(?:add|remove|toggle)Class|classList\.(?:add|remove|toggle))\(\s*(['"])(.*?)\1/

      # Bootstrap 4 classes and attributes that Bootstrap 5 renamed or dropped, shared with ESLint
      BOOTSTRAP_4 = JSON.parse(File.read(File.expand_path('../config/bootstrap4_leftovers.json', __dir__), encoding: 'UTF-8'))
      BOOTSTRAP_4_CLASSES = BOOTSTRAP_4['classes'].to_h do |entry|
        [/(?<![\w-])(?:#{entry['pattern']})(?![\w-])/, "Bootstrap 4 class: in Bootstrap 5, use #{entry['use']}."]
      end.freeze
      # As attributes (data-toggle="...") and as data: { toggle: ... } in Ruby
      BOOTSTRAP_4_ATTRIBUTES = BOOTSTRAP_4['attributes'].flat_map do |entry|
        message = "Bootstrap 4 attribute: in Bootstrap 5, use #{entry['use']}."
        [
          [/(?<![\w-])(?:#{entry['pattern']})(?![\w-])/, message],
          [/\bdata:\s*\{[^}]*?(?<![\w-])\K(?:#{entry['pattern'].delete_prefix('data-')}):/, message]
        ]
      end.freeze

      def run(processed_source)
        source = processed_source.file_content

        (PATTERNS.to_a + BOOTSTRAP_4_ATTRIBUTES).each do |pattern, message|
          source.scan(pattern) { add(processed_source, Regexp.last_match.begin(0)...Regexp.last_match.end(0), message) }
        end

        source.scan(CLASS_LISTS) do
          match = Regexp.last_match
          classes = match[2].gsub(/<%.*?%>/m) { |erb| ' ' * erb.length } # Ruby inside the attribute isn't a class
          check_classes(processed_source, classes, match.begin(2), label: true)
        end

        source.scan(SELECTS) do
          match = Regexp.last_match
          next if match[0].match?(FORM_SELECT)

          add(processed_source, match.begin(0)...(match.begin(0) + match[0][/\A\S+/].length), 'Selects take `form-select`.')
        end

        source.scan(CLASS_CALLS) do
          match = Regexp.last_match
          check_classes(processed_source, match[2], match.begin(2))
        end
      end

      private

      # Checks a list of class names that starts at offset in the source
      def check_classes(processed_source, classes, offset, label: false)
        checks = BOOTSTRAP_4_CLASSES.to_a
        checks << [/(?<![\w-])label(?![\w-])/, 'There is no `.label` class; use `badge text-bg-*`.'] if label
        checks.each do |pattern, message|
          classes.to_enum(:scan, pattern).each do
            range = (offset + Regexp.last_match.begin(0))...(offset + Regexp.last_match.end(0))
            add(processed_source, range, message)
          end
        end
      end

      def add(processed_source, range, message)
        add_offense(processed_source.to_source_range(range), "DesignClasses: #{message}")
      end
    end
  end
end
