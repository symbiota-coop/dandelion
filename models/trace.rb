class Trace
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account, optional: true, inverse_of: nil

  field :name, type: String
  field :status, type: String
  field :http_status, type: Integer
  # With the query string, its secret values filtered (see Trace.url_with_query)
  field :url, type: String
  field :user_agent, type: String
  field :http_method, type: String
  field :release, type: String
  # When the release was committed (see Trace.commit_time), so listing releases by age needs no lookups
  field :release_committed_at, type: Time
  field :xhr, type: Boolean
  field :started_at, type: Time
  field :duration_ms, type: Float
  field :span_count, type: Integer
  # The spans (see Trace.compact_spans) as JSON compressed with zstd, about a fifth the size of storing them as
  # documents, which matters most in Mongo's cache, where documents are held uncompressed. Read them with #spans
  field :spans_zstd, type: BSON::Binary
  # The pipeline (search.pipeline) and time of each Atlas Search query (search.query span), for Trace.search_summary,
  # which can't read them from the compressed spans. Left out of traces without one
  field :search_spans, type: Array

  validates_presence_of :name, :started_at

  # Span data that repeats what a span's op and description already say
  REDUNDANT_SPAN_DATA = %w[db.system db.name db.operation db.collection.name db.duration_ms].freeze

  # Called from Sentry's before_send_transaction, on Sentry's background thread.
  # Keeps what the span tree needs and leaves out the request's headers and cookies.
  def self.create_from_sentry_transaction(event)
    trace_context = event.contexts[:trace] || {}
    spans = compact_spans(JSON.parse(JSON.generate(event.spans || [])), event.start_timestamp.to_f)
    search_spans = spans.filter_map { |span| (pipeline = span.dig('data', 'search.pipeline')) && { 'pipeline' => pipeline, 'ms' => span['ms'] } }

    create(
      name: event.transaction,
      status: trace_context[:status],
      http_status: trace_context[:data]&.dig(Sentry::Span::DataConventions::HTTP_STATUS_CODE),
      url: url_with_query(event.request),
      user_agent: event.request&.headers&.dig('User-Agent'),
      http_method: event.request&.method,
      account_id: event.user&.dig(:id),
      release: event.release,
      release_committed_at: (commit_time(event.release) if event.release),
      xhr: event.tags&.dig(:xhr) == 'true',
      started_at: Time.at(event.start_timestamp),
      duration_ms: ((event.timestamp.to_f - event.start_timestamp.to_f) * 1000).round(2),
      span_count: spans.count,
      spans_zstd: pack_spans(spans),
      search_spans: (search_spans unless search_spans.empty?)
    )
  end

  COMMIT_TIMES = {}

  # When a commit was made: from the local git history if the deploy has it, otherwise from GitHub.
  # Looked up once per process, as a commit's time never changes
  def self.commit_time(commit)
    return COMMIT_TIMES[commit] if COMMIT_TIMES.key?(commit)

    COMMIT_TIMES[commit] = begin
      require 'open3'
      output, status = Open3.capture2('git', '-C', Padrino.root, 'show', '-s', '--format=%cI', commit, err: File::NULL)
      if status.success? && !output.strip.empty?
        Time.iso8601(output.strip)
      else
        Octokit::Client.new(access_token: ENV['GITHUB_ACCESS_TOKEN']).commit('symbiota-coop/dandelion', commit).commit.committer.date
      end
    rescue StandardError
      nil
    end
  end

  # Serves Trace.releases with a DISTINCT_SCAN, so it reads one index entry per release
  RELEASES_INDEX = { release: 1, release_committed_at: -1 }.freeze

  # The releases traces were saved by, with when each was committed, newest first. Releases whose commit time
  # wasn't found are left out
  def self.releases
    collection.aggregate([
                           { '$sort' => RELEASES_INDEX.stringify_keys },
                           { '$group' => { _id: '$release', committed_at: { '$first' => '$release_committed_at' } } }
                         ]).filter_map { |row| [row['_id'], row['committed_at']] if row['_id'] && row['committed_at'] }
                           .sort_by { |_release, time| time }.reverse
  end

  # Query parameters whose values can sign someone in or grant access (link_token, api_key, ics_key, OAuth codes...)
  SECRET_QUERY_PARAM = /token|key|secret|password|code|state|signature/i

  # Sentry's request url leaves out the query string, which tells apart e.g. the pages of a paginated list
  def self.url_with_query(request)
    return unless request&.url
    return request.url if request.query_string.blank?

    "#{request.url}?#{filter_query(request.query_string)}"
  end

  # A query string with the values of SECRET_QUERY_PARAMs replaced by [Filtered]. Sentry 7 gives the request's query as
  # the parsed params (with its own sensitive keys already [Filtered]), and spans' http.query as a string
  def self.filter_query(query)
    if query.is_a?(Hash)
      return query.map do |name, value|
        if value == Sentry::DataCollection::KeyValueCollection::FILTERED_VALUE || name.to_s.match?(SECRET_QUERY_PARAM)
          "#{CGI.escape(name.to_s)}=[Filtered]"
        else
          Rack::Utils.build_nested_query(name => value)
        end
      end.join('&')
    end

    query.split('&').map do |pair|
      name, value = pair.split('=', 2)
      value && CGI.unescape(name).match?(SECRET_QUERY_PARAM) ? "#{name}=[Filtered]" : pair
    end.join('&')
  end

  def self.pack_spans(spans)
    BSON::Binary.new(Zstd.compress(JSON.generate(spans)))
  end

  def self.unpack_spans(spans_zstd)
    spans_zstd ? JSON.parse(Zstd.decompress(spans_zstd.data)) : []
  end

  def spans
    Trace.unpack_spans(spans_zstd)
  end

  # Sentry's spans in order of start, cut down to what the span trees use: the parent's position in the list (none for
  # children of the transaction itself), op and description, start (ms into the transaction), time, self time (time
  # less the children's, so self times don't overlap) when it isn't the whole time, and status and data when they add
  # anything. A span's id is its position, and a span with no status is ok
  def self.compact_spans(spans, start_timestamp)
    span_ms = ->(span) { (span['timestamp'].to_f - span['start_timestamp'].to_f) * 1000 }
    children_ms = Hash.new(0)
    spans.each { |span| children_ms[span['parent_span_id']] += span_ms.call(span) }

    spans = spans.sort_by { |span| span['start_timestamp'].to_f }
    positions = spans.each_with_index.to_h { |span, i| [span['span_id'], i] }
    spans.map do |span|
      data = span['data']&.except(*REDUNDANT_SPAN_DATA)
      # The query string of an outgoing request (http.client span), which can carry an API key (Google's key=)
      data['http.query'] = filter_query(data['http.query']) if data&.dig('http.query').is_a?(String)
      ms = span_ms.call(span).round(3)
      self_ms = [span_ms.call(span) - children_ms[span['span_id']], 0].max.round(3)
      {
        'parent' => positions[span['parent_span_id']], 'op' => span['op'], 'description' => span['description'],
        'start_ms' => ((span['start_timestamp'].to_f - start_timestamp) * 1000).round(3), 'ms' => ms,
        'self_ms' => (self_ms unless self_ms == ms),
        'status' => (span['status'] unless span['status'] == 'ok'), 'data' => (data unless data.blank?)
      }.compact
    end
  end

  # The HTTP status if the request didn't succeed, or for traces without one, Sentry's status if it isn't ok
  def failure
    http_status ? (http_status.to_s unless (200..299).cover?(http_status)) : (status unless [nil, 'ok'].include?(status))
  end

  def self.slower_than(min_ms)
    self.and(:duration_ms.gte => min_ms)
  end

  # Also serves a transaction's traces sorted by duration on /stats/traces
  SUMMARY_INDEX = { name: 1, xhr: 1, duration_ms: -1 }.freeze

  # Count, total, p50, p99 and p100 (max) duration per transaction: per name and whether it's XHR (pagelets
  # share routes with pages). Most total time first.
  # Reads only fields in SUMMARY_INDEX, so with that index (which must exist: it's hinted) the spans aren't loaded.
  def self.summary
    collection.aggregate([
                           { '$match' => criteria.selector },
                           { '$group' => { _id: { name: '$name', xhr: '$xhr' } }.merge(duration_stats('$duration_ms')) },
                           { '$sort' => { total_ms: -1 } }
                         ], hint: SUMMARY_INDEX.stringify_keys).map do |row|
      { name: row['_id']['name'], xhr: row['_id']['xhr'] }.merge(duration_stats_row(row))
    end
  end

  # The same for Atlas Search queries, per pipeline (see Searchable): text, vector, or text_fallback when the vector
  # search timed out. An index on search_spans.pipeline means only traces with a search are read
  def self.search_summary
    collection.aggregate([
                           { '$match' => criteria.and('search_spans.pipeline' => { '$type' => 'string' }).selector },
                           { '$unwind' => '$search_spans' },
                           { '$group' => { _id: '$search_spans.pipeline' }.merge(duration_stats('$search_spans.ms')) },
                           { '$sort' => { total_ms: -1 } }
                         ]).map do |row|
      { name: row['_id'] }.merge(duration_stats_row(row))
    end
  end

  # $group fields for the count, total, p50, p99 and p100 of a field of times in ms, read by duration_stats_row
  def self.duration_stats(field)
    {
      count: { '$sum' => 1 },
      total_ms: { '$sum' => field },
      percentiles_ms: { '$percentile' => { input: field, p: [0.5, 0.99], method: 'approximate' } },
      p100_ms: { '$max' => field }
    }
  end

  def self.duration_stats_row(row)
    { count: row['count'], total_ms: row['total_ms'], p50_ms: row['percentiles_ms'][0], p99_ms: row['percentiles_ms'][1], p100_ms: row['p100_ms'] }
  end

  # This trace's spans as rows in tree order (each followed by its children, siblings in order of start), for
  # stats/trace.erb: an id (the span's position), a parent_id (nil for children of the transaction itself), a depth,
  # a count of children, an op, description, data and status, and its time, self time and start offset in ms
  def span_tree
    spans = self.spans
    children = spans.each_index.group_by { |i| spans[i]['parent'] }

    rows = []
    add_rows = lambda do |parent, depth|
      (children[parent] || []).each do |i|
        span = spans[i]
        rows << { id: i.to_s, parent_id: parent&.to_s, depth: depth, children: children[i]&.size || 0,
                  op: span['op'], description: span['description'], data: span['data'], status: span['status'],
                  ms: span['ms'], self_ms: span['self_ms'] || span['ms'], offset_ms: span['start_ms'] }
        add_rows.call(i, depth + 1)
      end
    end
    add_rows.call(nil, 0)
    rows
  end
end
