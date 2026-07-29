class Hash
  def to_markdown(level: 1, title: nil, html_keys: [])
    lines = []
    header = '#' * level

    lines << "#{header} #{self[title]}\n" if title && self[title]

    each do |key, value|
      next if key == title

      formatted_key = key.to_s.tr('_', ' ').capitalize
      lines << format_value(formatted_key, value, level, html_keys.include?(key))
    end

    lines.flatten.compact.join("\n")
  end

  private

  def format_value(key, value, level, is_html = false)
    header = '#' * (level + 1)
    case value
    when nil
      nil # Skip nil values
    when Hash
      ["#{header} #{key}\n", value.to_markdown(level: level + 1)]
    when Array
      if value.empty?
        nil
      elsif value.first.is_a?(Hash)
        ["#{header} #{key}\n", value.map { |v| v.to_markdown(level: level + 1) }.join("\n")]
      else
        "#{header} #{key}\n#{value.join(', ')}\n"
      end
    when Time, DateTime
      "#{header} #{key}\n#{value.to_fs(:iso8601)}\n"
    else
      content = is_html ? ReverseMarkdown.convert(value.to_s, unknown_tags: :bypass).strip : value
      "#{header} #{key}\n#{content}\n"
    end
  end
end

class Array
  def to_markdown(title: nil, html_keys: [])
    return '' if empty?

    if first.is_a?(Hash)
      map do |item|
        item.to_markdown(title: title, html_keys: html_keys)
      end.join("\n---\n\n")
    else
      map(&:to_s).join(', ')
    end
  end
end
