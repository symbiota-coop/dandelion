Dandelion::App.helpers do
  def md(text, hard_wrap: false)
    markdown = Redcarpet::Markdown.new(hard_wrap ? Redcarpet::Render::HTML.new(hard_wrap: true) : Redcarpet::Render::HTML, autolink: true, tables: true, fenced_code_blocks: true)
    markdown.render(text)
  end

  def timeago(time)
    %(<abbr class="timeago" title="#{time.iso8601}">#{time}</abbr>).html_safe
  end

  def youtube_embed_url(url)
    if url =~ %r{(?:youtube\.com/(?:[^/]+/.+/|(?:v|e(?:mbed)?)/|.*[?&]v=)|youtu\.be/)([^"&?/\s]{11})}
      "https://www.youtube.com/embed/#{Regexp.last_match(1)}"
    else
      url # Return original URL if it doesn't match YouTube format
    end
  end

  def money_symbol(currency)
    Money.new(0, currency).symbol
  rescue Money::Currency::UnknownCurrency
    currency
  end

  def m(amount, currency)
    if amount.is_a?(Money)
      amount.exchange_to(currency).format(no_cents_if_whole: true)
    else
      Money.new(amount * 100, currency).format(no_cents_if_whole: true)
    end
  rescue Money::Bank::UnknownRate, Money::Currency::UnknownCurrency
    "#{currency} #{amount}"
  end

  def u(url)
    URI::Parser.new.escape(url) if url
  end

  def form_or_tag_field(form, type, field_name, **options)
    if defined?(form) && form
      # For check_box, strip value/checked options as form builder handles these via model
      options = options.except(:value, :checked) if type == :check_box
      form.send(type, field_name, **options)
    else
      send("#{type}_tag", nil, **options, 'data-field': field_name.to_s)
    end
  end

  def checkbox(name, slug: nil, checked: false, form_group_class: nil, disabled: false)
    slug ||= name.force_encoding('utf-8').parameterize.underscore
    checked_or_param = checked || params[:"#{slug}"]
    %(<div class="form-group #{form_group_class}">
       <div class="checkbox-inline #{'checked' if checked_or_param}">
          #{check_box_tag :"#{slug}", checked: checked_or_param, id: "#{slug}_checkbox", disabled: disabled}
          <label for="#{slug}_checkbox">#{name}</label>
        </div>
    </div>).html_safe
  end

  def quick_colors(count: 13, saturation: 80, lightness: 50, primary: '#00B963')
    step = 360.0 / count
    base_hue = Chroma.paint(primary).hsl.h.round
    (0...count).map { |i| i == 0 ? primary : Chroma.paint("hsl(#{(base_hue + (i * step)) % 360}, #{saturation}%, #{lightness}%)").to_hex }
  end

  def clamp_color(hex, min_contrast: 2, min_lightness: 0.25)
    hsl = Chroma.paint(hex).hsl
    if LuminosityContrast.ratio(hex.delete('#'), 'fff') < min_contrast
      low = 0.0
      high = hsl.l
      7.times do
        mid = (low + high) / 2.0
        test_hex = Chroma.paint("hsl(#{hsl.h}, #{(hsl.s * 100).round}%, #{(mid * 100).round}%)").to_hex
        if LuminosityContrast.ratio(test_hex.delete('#'), 'fff') >= min_contrast
          low = mid
        else
          high = mid
        end
      end
      Chroma.paint("hsl(#{hsl.h}, #{(hsl.s * 100).round}%, #{(low * 100).round}%)").to_hex
    elsif hsl.l < min_lightness
      Chroma.paint("hsl(#{hsl.h}, #{(hsl.s * 100).round}%, #{(min_lightness * 100).round}%)").to_hex
    else
      hex
    end
  end

  def blurred_image_tag(image, width: nil, height: nil, full_size: '992x992', md_size: nil, css_class: 'w-100', id: nil)
    attrs = []
    attrs << %(class="#{css_class}") if css_class
    attrs << %(id="#{id}") if id
    attrs << %(style="aspect-ratio: #{width} / #{height}") if width && height
    attrs << %(src="#{u image.thumb('32x32').url}")
    attrs << %(data-src="#{u image.thumb(full_size).url}")
    attrs << %(data-src-md="#{u image.thumb(md_size).url}") if md_size
    attrs << %{
    onload="if (this.dataset.src && !this.dataset.loaded) {
      var el = this;
      var img = new Image();
      var targetSrc = (el.dataset.srcMd && window.innerWidth < 992) ? el.dataset.srcMd : el.dataset.src;
      img.src = targetSrc;
      if (img.complete) {
        el.dataset.loaded = 'true';
        el.src = targetSrc;
      } else {
        el.style.filter = 'blur(8px)';
        img.onload = function() {
          el.dataset.loaded = 'true';
          el.src = targetSrc;
          el.style.filter = 'none';
        }
      }
    }"
  }
    %(<img #{attrs.join(' ')}>).html_safe
  end
end
