# The books and films on /books, /films and the Daily, from the CSVs in stephenreid321/stephenreid, fetched once per
# process (boot.rb fetches them as the app boots).
#
# A failed fetch (a 5xx, a refused connection or a timeout) is tried up to 3 times at boot, and if it still fails the
# list is cached empty until the process restarts. We don't retry on later requests: if GitHub was down, each request
# to /books, /films or the Daily would wait on it again (up to 15 s a try, two CSVs for books). Losing those pages until
# the next deploy is the smaller cost.
module Library
  def self.books
    LIBRARY_CACHE[:books] ||= begin
      dandelion_ids = csv('dandelion_books').filter_map { |b| b[:book_id] }.to_set
      csv('goodreads_library_export').select { |b| dandelion_ids.include?(b[:book_id]) }.map do |b|
        b.merge(
          slug: b[:title].parameterize,
          cover_image: "/images/books/#{b[:book_id]}.jpg",
          original_publication_year_or_year_published: b[:original_publication_year] || b[:year_published]
        )
      end
    end
  end

  def self.films
    LIBRARY_CACHE[:films] ||= csv('films').map { |f| f.merge(slug: f[:name].parameterize) }
  end

  def self.csv(name)
    response = Faraday.new do |conn|
      conn.options.timeout = 10
      conn.options.open_timeout = 5
      conn.request :retry, max: 2, interval: 1, backoff_factor: 2,
                           exceptions: [Faraday::ServerError, Faraday::ConnectionFailed, Faraday::TimeoutError]
      conn.response :raise_error
    end.get("https://raw.githubusercontent.com/stephenreid321/stephenreid/master/data/#{name}.csv")
    CSV.parse(response.body, headers: true).map do |row|
      row.to_h
         .transform_keys { |k| k.to_s.downcase.gsub(/\s+/, '_').to_sym }
         .transform_values { |v| v.nil? || v.empty? ? nil : v }
    end
  rescue StandardError => e
    ErrorReporting.capture_exception(e, context: { name: name })
    []
  end
end
