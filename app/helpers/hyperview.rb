Dandelion::App.helpers do
  def hyperview_request?
    request.env['HTTP_ACCEPT']&.include?('application/vnd.hyperview+xml') ||
      request.env['HTTP_X_HYPERVIEW'] == 'true' ||
      request.env['HTTP_USER_AGENT']&.include?('Hyperview')
  end

  def hyperview(template, options = {})
    content_type 'application/vnd.hyperview+xml'
    options[:layout] = :'hyperview.hxml' unless options[:layout]
    erb :"#{template}.hxml", options
  end

  def hyperview_partial(template, options = {})
    content_type 'application/vnd.hyperview+xml'
    template = template.to_s.gsub('/', '/_')
    erb :"#{template}.hxml", options.merge(layout: false)
  end

  def hyperview_styles(template, options = {})
    content_type 'application/vnd.hyperview+xml'
    erb :"hyperview_styles/#{template}.hxml.styles", options.merge(layout: false)
  end
end
