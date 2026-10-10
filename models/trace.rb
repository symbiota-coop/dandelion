class Trace
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account, optional: true, inverse_of: nil

  field :name, type: String
  field :status, type: String
  field :http_status, type: Integer
  field :url, type: String
  field :http_method, type: String
  field :release, type: String
  field :xhr, type: Boolean
  field :started_at, type: Time
  field :duration_ms, type: Float
  field :span_count, type: Integer
  # The spans (see Trace.compact_spans) as JSON compressed with zstd, about a fifth the size of storing them as
  # documents, which matters most in Mongo's cache, where documents are held uncompressed. Read them with #spans
  field :spans_zstd, type: BSON::Binary

  validates_presence_of :name, :started_at

  # Span data that repeats what a span's op and description already say
  REDUNDANT_SPAN_DATA = %w[db.system db.name db.operation db.collection.name db.duration_ms].freeze

  # Called from Sentry's before_send_transaction, on Sentry's background thread.
  # Keeps what the span tree needs and leaves out the request's headers and cookies.
  def self.create_from_sentry_transaction(event)
    trace_context = event.contexts[:trace] || {}
    spans = compact_spans(JSON.parse(JSON.generate(event.spans || [])), event.start_timestamp.to_f)

    create(
      name: event.transaction,
      status: trace_context[:status],
      http_status: trace_context[:data]&.dig(Sentry::Span::DataConventions::HTTP_STATUS_CODE),
      url: event.request&.url,
      http_method: event.request&.method,
      account_id: event.user&.dig(:id),
      release: event.release,
      xhr: event.tags&.dig(:xhr) == 'true',
      started_at: Time.at(event.start_timestamp),
      duration_ms: ((event.timestamp.to_f - event.start_timestamp.to_f) * 1000).round(2),
      span_count: spans.count,
      spans_zstd: pack_spans(spans)
    )
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
                           { '$group' => {
                             _id: { name: '$name', xhr: '$xhr' },
                             count: { '$sum' => 1 },
                             total_ms: { '$sum' => '$duration_ms' },
                             percentiles_ms: { '$percentile' => { input: '$duration_ms', p: [0.5, 0.99], method: 'approximate' } },
                             p100_ms: { '$max' => '$duration_ms' }
                           } },
                           { '$sort' => { total_ms: -1 } }
                         ], hint: SUMMARY_INDEX.stringify_keys).map do |row|
      { name: row['_id']['name'], xhr: row['_id']['xhr'], count: row['count'], total_ms: row['total_ms'],
        p50_ms: row['percentiles_ms'][0], p99_ms: row['percentiles_ms'][1], p100_ms: row['p100_ms'] }
    end
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
