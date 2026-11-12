# The classes rich text may keep: what CKEditor writes, plus those our own markup puts in before it's sanitized (the
# [buttons] in organisation intros, the provider icons in flash messages). Any other class is dropped, as the stylesheets
# every page loads have classes that take content out of the flow (position-fixed top-0 z-3, offcanvas show...), which
# would let rich text lay a fake panel over the whole page
module RichTextClasses
  ALLOWED = %w[
    image image_resized image-style-align-left image-style-align-center image-style-align-right image-style-side
    table table-bordered media raw-html-embed lead small action
    btn btn-primary mb-1 bi
  ].to_set.freeze

  TRANSFORMER = lambda do |env|
    node = env[:node]
    return unless node.element? && node['class']

    classes = node['class'].split.select { |c| ALLOWED.include?(c) || c.start_with?('language-', 'bi-') }
    classes.empty? ? node.remove_attribute('class') : node['class'] = classes.join(' ')
  end
end

# No <style> elements, which RELAXED allows: their rules (even with only the properties below) would apply to the whole
# page, letting someone's message or description restyle or hide the page around it
Sanitize::Config::DANDELION = Sanitize::Config.merge(Sanitize::Config::RELAXED,
                                                     elements: Sanitize::Config::RELAXED[:elements] - %w[style] + %w[oembed],
                                                     attributes: Sanitize::Config::RELAXED[:attributes].merge(
                                                       {
                                                         :all => %w[class target],
                                                         'oembed' => ['url'],
                                                         'figure' => ['style'],
                                                         'span' => ['style'],
                                                         'h1' => ['style'],
                                                         'h2' => ['style'],
                                                         'h3' => ['style'],
                                                         'h4' => ['style'],
                                                         'h5' => ['style'],
                                                         'h6' => ['style'],
                                                         'p' => ['style']
                                                       }
                                                     ),
                                                     css: {
                                                       properties: %w[width text-align color background-color]
                                                     },
                                                     protocols: Sanitize::Config::RELAXED[:protocols].merge(
                                                       {
                                                         'oembed' => { 'url' => %w[http https] }
                                                       }
                                                     ),
                                                     transformers: [RichTextClasses::TRANSFORMER],
                                                     remove_contents: true)

Sanitize::Config::IFRAMES = Sanitize::Config.merge(Sanitize::Config::DANDELION,
                                                   elements: Sanitize::Config::DANDELION[:elements] + %w[iframe],
                                                   attributes: Sanitize::Config::DANDELION[:attributes].merge(
                                                     {
                                                       'iframe' => %w[src width height frameborder allowfullscreen style]
                                                     }
                                                   ),
                                                   css: Sanitize::Config::DANDELION[:css],
                                                   protocols: Sanitize::Config::DANDELION[:protocols].merge(
                                                     {
                                                       'iframe' => { 'src' => %w[http https] }
                                                     }
                                                   ),
                                                   remove_contents: true)
