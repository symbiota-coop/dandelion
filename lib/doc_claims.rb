require 'digest'

# The claims the docs (app/views/docs/md) make that tests check (AGENTS.md, Docs and tests). A claim is marked with
# <!-- claim: id --> after it, and is the text before the marker, back to the start of its line (less any list bullet
# or quote marker) or the marker before it. A test that checks one says so with covers 'page/id@hash', where the hash is of the claim's text, so a change to
# what the docs say fails test/lint_test.rb until the test is checked against the new text
module DocClaims
  MARKER = /<!-- claim: ([a-z0-9-]+) -->/

  # The markers come out before the docs render: Redcarpet escapes an HTML comment inside a paragraph
  def self.strip(source)
    source.gsub(/ ?#{MARKER}/o, '')
  end

  # Each claim in a page's Markdown, as { id:, text:, hash:, line: }
  def self.claims(source)
    source.each_line.with_index(1).flat_map do |line, number|
      start = 0
      line.to_enum(:scan, MARKER).map do
        match = Regexp.last_match
        text = line[start...match.begin(0)].sub(/\A\s*(?:>\s*)*(?:(?:[-*]|\d+\.)\s+)?/, '').gsub(/\s+/, ' ').strip
        start = match.end(0)
        { id: match[1], text: text, hash: hash(text), line: number }
      end
    end
  end

  def self.hash(text)
    Digest::SHA256.hexdigest(text)[0, 6]
  end
end
