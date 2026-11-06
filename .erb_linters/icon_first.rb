# frozen_string_literal: true

module ERBLint
  module Linters
    # A button's icon comes before its text (<i class="bi bi-plus-lg"></i> Create a team), as it does in nearly all of
    # them, so a row of buttons reads alike. A loading spinner (bi-spin), shown after the text while it waits, is fine
    class IconFirst < Linter
      include LinterRegistry

      MESSAGE = 'IconFirst: Put the icon before the text: `<i class="bi bi-..."></i> Label`.'

      # <a> and <button> tags with a btn class, and what's inside them
      BUTTONS = %r{<(a|button)\b(?:[^>"]|"[^"]*")*\bclass="[^"]*\bbtn\b[^"]*"(?:[^>"]|"[^"]*")*>(.*?)</\1>}m
      ICON = %r{<i\b[^>]*\bclass="(?![^"]*\bbi-spin\b)[^"]*\bbi\b[^"]*"[^>]*></i>}

      def run(processed_source)
        # ERB blanked out first, at the same length so offsets still match: what it outputs counts as text, as an X; its
        # comments and logic (<% if %>), and any > inside it, don't
        source = processed_source.file_content.gsub(/<%(=?)(.*?)%>/m) { |erb| (Regexp.last_match(1) == '=' ? 'X' : ' ').ljust(erb.length) }
        source.scan(BUTTONS) do
          match = Regexp.last_match
          inner = match[2]
          next unless (icon = inner.index(ICON))

          text = inner.gsub(%r{<[^>]+>}) { |t| ' ' * t.length }.gsub(/&\w+;/) { |e| ' ' * e.length }.index(/[[:alnum:]]/)
          next unless text && text < icon

          start = match.begin(2) + icon
          add_offense(processed_source.to_source_range(start...(start + inner[ICON].length)), MESSAGE)
        end
      end
    end
  end
end
