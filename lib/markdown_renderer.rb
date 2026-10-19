# Markdown is rendered here and nowhere else, so the same text renders the same way in a page, an email or a summary
# (not named Markdown, which Redcarpet defines)
module MarkdownRenderer
  EXTENSIONS = { autolink: true, tables: true, fenced_code_blocks: true }.freeze

  # trusted: only for our own files (docs, terms...), which may use any HTML; everything else is sanitized with
  # Sanitize::Config::DANDELION. hard_wrap: single newlines become <br>. inline: for one paragraph of model output
  # (feedback summaries): HTML in the text stays text, links to anything but http(s) and mailto stay text (feedback in
  # the prompt could ask for a [link](javascript:...)), and the <p> is dropped
  def self.render(text, trusted: false, hard_wrap: false, inline: false)
    renderer = Redcarpet::Render::HTML.new(hard_wrap: hard_wrap, escape_html: inline, safe_links_only: inline)
    html = Redcarpet::Markdown.new(renderer, **EXTENSIONS).render(text.to_s)
    html = Sanitize.fragment(html, Sanitize::Config::DANDELION) unless trusted
    html = html.strip.delete_prefix('<p>').delete_suffix('</p>') if inline
    html.html_safe
  end
end
