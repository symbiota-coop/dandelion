module HttpUrl
  # Addressable takes non-ASCII URLs (https://example.com/café) as they are, but also takes spaces, so those are rejected here
  def self.parse(url)
    return if url.to_s.match?(/\s/)

    uri = Addressable::URI.parse(url.to_s)
    uri if uri.scheme&.downcase.in?(%w[http https]) && uri.host.present?
  rescue Addressable::URI::InvalidURIError
    nil
  end

  def self.valid?(url)
    parse(url).present?
  end

  # For display: https://www.bücher.de/x is bücher.de
  def self.host(url)
    parse(url)&.host&.delete_prefix('www.')
  end

  # Strips the value, and puts https:// in front of a bare domain
  def self.normalize(url)
    url = url&.strip
    return if url.blank?

    url.match?(/\A[a-z][a-z0-9+.-]*:/i) ? url : "https://#{url}"
  end
end
