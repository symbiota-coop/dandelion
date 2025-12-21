module EmailHelper
  class TemplateContext
    def initialize(locals)
      locals.each do |key, value|
        define_singleton_method(key) { value }
      end
    end

    def get_binding
      binding
    end
  end

  def self.render(template_name, **locals)
    context = TemplateContext.new(locals)
    ERB.new(File.read(Padrino.root("app/views/emails/#{template_name}.erb"))).result(context.get_binding)
  end

  def self.html(template_or_first_arg = nil, template: nil, content: nil, layout: 'email.erb', **locals, &block)
    # If first arg is a symbol or string, treat it as template name
    template = template_or_first_arg.to_s if template_or_first_arg.is_a?(Symbol) || template_or_first_arg.is_a?(String)

    raise ArgumentError, 'Either template or content must be provided' if template.nil? && content.nil? && layout == 'email.erb'
    raise ArgumentError, 'Cannot provide both template and content' if template && content

    content = render(template.to_sym, **locals) if template
    content = block.call(content) if block_given?
    context = TemplateContext.new(locals.merge(content: content))

    Premailer.new(
      ERB.new(File.read(Padrino.root("app/views/layouts/#{layout}"))).result(context.get_binding),
      with_html_string: true,
      adapter: 'nokogiri',
      input_encoding: 'UTF-8'
    ).to_inline_css
  end
end
