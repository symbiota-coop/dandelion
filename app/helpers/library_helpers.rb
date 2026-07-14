LIBRARY_CACHE = {}

Dandelion::App.helpers do
  def library_csv(name)
    require 'csv'
    CSV.parse(
      Faraday.get("https://rawcdn.githack.com/stephenreid321/stephenreid/master/data/#{name}.csv").body,
      headers: true
    ).map do |row|
      row.to_h
         .transform_keys { |k| k.to_s.downcase.gsub(/\s+/, '_').to_sym }
         .transform_values { |v| v.nil? || v.empty? ? nil : v }
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

    dandelion_ids = library_csv('dandelion_books').map { |b| b[:book_id] }.compact.to_set
    return [] if dandelion_ids.empty?

    rows = library_csv('goodreads_library_export').select { |b| dandelion_ids.include?(b[:book_id]) }.map do |b|
      b.merge(
        slug: b[:title].parameterize,
        cover_image: "/images/books/#{b[:book_id]}.jpg",
        original_publication_year_or_year_published: b[:original_publication_year] || b[:year_published]
      )
    end
    LIBRARY_CACHE[:books] = rows if rows.any?
    rows
  end

  def library_films
    return LIBRARY_CACHE[:films] if LIBRARY_CACHE[:films]

    rows = library_csv('films').map do |f|
      f.merge(slug: f[:name].parameterize)
    end
    LIBRARY_CACHE[:films] = rows if rows.any?
    rows
  end
end
