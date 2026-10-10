class Trace
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions

  belongs_to_without_parent_validation :account, optional: true, inverse_of: nil

  field :name, type: String
  field :op, type: String
  field :status, type: String
  field :http_status, type: Integer
  field :trace_id, type: String
  field :url, type: String
  field :http_method, type: String
  field :release, type: String
  field :xhr, type: Boolean
  field :started_at, type: Time
  field :duration_ms, type: Float
  field :span_count, type: Integer
  field :spans, type: Array

  validates_presence_of :name, :started_at

  # Span data that repeats what a span's op and description already say
  REDUNDANT_SPAN_DATA = %w[db.system db.name db.operation db.collection.name db.duration_ms].freeze

  # How far back a merged span tree looks (see Trace.span_tree)
  SPAN_TREE_WINDOW = 3.hours

  # Called from Sentry's before_send_transaction, on Sentry's background thread.
  # Keeps what the span tree needs and leaves out the request's headers and cookies.
  def self.create_from_sentry_transaction(event)
    trace_context = event.contexts[:trace] || {}
    spans = compact_spans(JSON.parse(JSON.generate(event.spans || [])), event.start_timestamp.to_f)

    create(
      name: event.transaction,
      op: trace_context[:op],
      status: trace_context[:status],
      http_status: trace_context[:data]&.dig(Sentry::Span::DataConventions::HTTP_STATUS_CODE),
      trace_id: trace_context[:trace_id],
      url: event.request&.url,
      http_method: event.request&.method,
      account_id: event.user&.dig(:id),
      release: event.release,
      xhr: event.tags&.dig(:xhr) == 'true',
      started_at: Time.at(event.start_timestamp),
      duration_ms: ((event.timestamp.to_f - event.start_timestamp.to_f) * 1000).round(2),
      span_count: spans.count,
      spans: spans
    )
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

  SUMMARY_INDEX = { name: 1, xhr: 1, created_at: -1, duration_ms: 1 }.freeze

  # Count, total and mean, p50, p99 and max (p100) duration per transaction: per name and whether it's XHR (pagelets
  # share routes with pages), or with by_xhr: false, per name alone. Most total time first.
  # Reads only fields in SUMMARY_INDEX, so with that index (which must exist: it's hinted) the spans aren't loaded.
  def self.summary(by_xhr: true)
    collection.aggregate([
                           { '$match' => criteria.selector },
                           { '$group' => {
                             _id: by_xhr ? { name: '$name', xhr: '$xhr' } : { name: '$name' },
                             count: { '$sum' => 1 },
                             total_ms: { '$sum' => '$duration_ms' },
                             percentiles_ms: { '$percentile' => { input: '$duration_ms', p: [0.5, 0.99], method: 'approximate' } },
                             max_ms: { '$max' => '$duration_ms' }
                           } },
                           { '$sort' => { total_ms: -1 } }
                         ], hint: SUMMARY_INDEX.stringify_keys).map do |row|
      { name: row['_id']['name'], xhr: row['_id']['xhr'], count: row['count'], total_ms: row['total_ms'], avg_ms: row['total_ms'] / row['count'],
        p50_ms: row['percentiles_ms'][0], p99_ms: row['percentiles_ms'][1], max_ms: row['max_ms'] }
    end
  end

  # Span trees, for stats/_span_tree.erb, are rows in tree order (each followed by its children) with an id, a parent_id
  # (nil at the top), a depth, a count of children, an op and description, how often it happens per trace,
  # and its time, self time and start offset in ms.

  # This trace's spans as a tree, siblings in order of start, each with its data and status
  def span_tree
    Trace.trace_span_tree(spans || [])
  end

  # Spans without a parent (children of the transaction itself) are at the top
  def self.trace_span_tree(spans)
    children = spans.each_index.group_by { |i| spans[i]['parent'] }

    flatten_tree(children, nil) do |i|
      span = spans[i]
      { op: span['op'], description: span['description'], data: span['data'], status: span['status'], per_trace: 1,
        ms: span['ms'], self_ms: span['self_ms'] || span['ms'], offset_ms: span['start_ms'] }
    end
  end

  # All the traces' span trees merged into one: spans with the same op and description under the same chain of parents
  # are one row, with how often it happens, its time and self time, all per trace, and how far into the trace it first
  # starts on average (over the traces it's in). Siblings are in order of time, most first.
  def self.span_tree
    traces = 0
    nodes = {}
    # Streamed from a cursor, so only the merged tree is held in memory
    collection.find(criteria.selector).projection(spans: 1).each do |doc|
      traces += 1
      paths = {}
      first_offsets = {}
      trace_span_tree(doc['spans'] || []).each do |row|
        path = paths[row[:id]] = paths.fetch(row[:parent_id], []) + [[row[:op], row[:description]]]
        node = nodes[path] ||= { count: 0, ms: 0.0, self_ms: 0.0, offset_ms: 0.0, traces: 0 }
        node[:count] += 1
        node[:ms] += row[:ms]
        node[:self_ms] += row[:self_ms]
        first_offsets[path] = [first_offsets[path], row[:offset_ms]].compact.min
      end
      first_offsets.each do |path, offset_ms|
        nodes[path][:offset_ms] += offset_ms
        nodes[path][:traces] += 1
      end
    end

    children = nodes.keys.sort_by { |path| -nodes[path][:ms] }.group_by { |path| path[0..-2] }
    flatten_tree(children, []) do |path|
      node = nodes[path]
      { op: path.last[0], description: path.last[1], per_trace: node[:count].to_f / traces,
        ms: node[:ms] / traces, self_ms: node[:self_ms] / traces, offset_ms: node[:offset_ms] / node[:traces] }
    end
  end

  # Rows in tree order from each node's children (under the given root), with what the block gives for each node.
  # Ids are row numbers
  def self.flatten_tree(children, root, &)
    rows = []
    add_rows = lambda do |node, parent_id, depth|
      (children[node] || []).each do |child|
        id = rows.size.to_s
        rows << { id: id, parent_id: parent_id, depth: depth, children: children[child]&.size || 0 }.merge(yield(child))
        add_rows.call(child, id, depth + 1)
      end
    end
    add_rows.call(root, nil, 0)
    rows
  end

  # A span tree's rows summed by the given keys (:op, or :op and :description, wherever the spans are in the tree):
  # spans per trace, time and self time, most self time first. Self times don't overlap, so they add up across rows
  def self.span_totals(span_tree, *keys)
    totals = span_tree.group_by { |row| row.values_at(*keys) }.map do |values, rows|
      keys.zip(values).to_h.merge(%i[per_trace ms self_ms].to_h { |key| [key, rows.sum { |row| row[key] }] })
    end
    totals.sort_by { |row| -row[:self_ms] }
  end
end
