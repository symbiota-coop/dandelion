Dandelion::App.helpers do
  # A script tag, or a stylesheet's link tag for a .css file, for a file on the CDN, with the hash rake
  # frontend:integrity recorded for it (config/frontend_integrity.rb), so the browser won't run the file if it changes
  def cdn_tag(url, **attributes)
    attributes = attributes.merge(integrity: FRONTEND_INTEGRITY.fetch(url), crossorigin: 'anonymous')
    if url.end_with?('.css')
      tag(:link, attributes.merge(rel: 'stylesheet', href: url))
    else
      content_tag(:script, '', attributes.merge(src: url))
    end
  end
end
