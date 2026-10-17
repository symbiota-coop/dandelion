Dandelion::App.helpers do
  # A script tag, or a stylesheet's link tag for a .css file, for a file on the CDN: an npm package's file at the version
  # frontend/package.json names (cdn_tag 'fullcalendar', 'all/global.js'), or the URL of a file that isn't an npm
  # package's. It carries the hash rake frontend:integrity recorded for the file (frontend/integrity.json), so the
  # browser won't run it if it changes
  def cdn_tag(package_or_url, file = nil, **attributes)
    url = file ? FRONTEND_NPM_URL.call(package_or_url, file) : package_or_url
    attributes = attributes.merge(integrity: FRONTEND_INTEGRITY.fetch(url), crossorigin: 'anonymous')
    if url.end_with?('.css')
      tag(:link, attributes.merge(rel: 'stylesheet', href: url))
    else
      content_tag(:script, '', attributes.merge(src: url))
    end
  end
end
