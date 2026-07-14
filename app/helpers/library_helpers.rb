LIBRARY_CACHE = {}

Dandelion::App.helpers do
  def library_csv(name)
    require 'csv'
    CSV.parse(
      Faraday.get("https://rawcdn.githack.com/stephenreid321/stephenreid/master/data/#{name}.csv").body,
      headers: true
    ).map do |row|
      row.to_h.transform_keys(&:to_sym).transform_values { |v| v.nil? || v.empty? ? nil : v }
    end
  rescue StandardError => e
    ErrorReporting.capture_exception(e, context: { name: name })
    []
  end

  def library_image_url(path)
    return unless path

    "https://rawcdn.githack.com/stephenreid321/stephenreid/master/app/assets#{path}"
  end

  def library_books
    return LIBRARY_CACHE[:books] if LIBRARY_CACHE[:books]

    rows = library_csv('books')
    LIBRARY_CACHE[:books] = rows if rows.any?
    rows
  end

  def library_films
    return LIBRARY_CACHE[:films] if LIBRARY_CACHE[:films]

    rows = library_csv('films')
    LIBRARY_CACHE[:films] = rows if rows.any?
    rows
  end
end

