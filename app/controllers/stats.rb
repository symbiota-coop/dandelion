Dandelion::App.controller do
  before do
    admins_only!
  end

  get '/stats/referrals' do
    @organisations = Organisation.and(:referrer_id.ne => nil).includes(:referrer, :reward_claimer)
    erb :'stats/referrals'
  end

  get '/stats/charts' do
    erb :'stats/charts'
  end

  get '/stats/contributions' do
    erb :'stats/contributions'
  end

  get '/stats/feedback' do
    @event_feedbacks = EventFeedback.includes(:account, event: :organisation).order('created_at desc')
    @event_feedbacks = @event_feedbacks.and(:id.in => search(EventFeedback, @event_feedbacks, params[:q], 25).map(&:id)) if params[:q]
    @event_feedbacks = @event_feedbacks.and(:rating.ne => 5) if params[:hide_5_stars]
    erb :'stats/feedback'
  end

  get '/stats/orders' do
    @orders = Order.includes(:account, :event, :revenue_sharer, :discount_code).order('created_at desc')
    @orders = @orders.and(application_fee_paid_to_dandelion: true, :application_fee_amount.gt => 0) if !params[:search] || params[:donation_to_dandelion]
    erb :'stats/orders'
  end

  get '/stats/organisations' do
    @from = params[:from] ? parse_date(params[:from]) : 3.months.ago.to_date
    @to = params[:to] ? parse_date(params[:to]) : Date.today
    created_at = { '$gte' => @from.to_time(:utc), '$lt' => (@to + 1.day).to_time(:utc) }

    # Sums and counts by event in the database, rather than loading every order and ticket (raw aggregations skip the paranoia scope, so exclude deleted orders and tickets here)
    order_sums = Order.collection.aggregate([
                                              { '$match' => { created_at: created_at, deleted_at: nil, value: { '$ne' => nil }, currency: { '$in' => FIAT_CURRENCIES } } },
                                              { '$group' => { _id: { event_id: '$event_id', currency: '$currency' }, value: { '$sum' => '$value' } } }
                                            ]).to_a
    ticket_counts = Ticket.collection.aggregate([
                                                  { '$match' => { created_at: created_at, deleted_at: nil, price: { '$gt' => 0 } } },
                                                  { '$group' => { _id: '$event_id', count: { '$sum' => 1 } } }
                                                ]).to_a.to_h { |r| [r['_id'], r['count']] }

    event_ids = (order_sums.map { |r| r['_id']['event_id'] } + ticket_counts.keys).uniq
    organisation_id_by_event = Event.and(:id.in => event_ids).pluck(:id, :organisation_id).to_h

    @rows = Hash.new { |h, k| h[k] = { events: 0, tickets: 0, value: Money.new(0, 'GBP') } }
    organisation_id_by_event.each do |event_id, organisation_id|
      @rows[organisation_id][:events] += 1
      @rows[organisation_id][:tickets] += ticket_counts[event_id] || 0
    end
    order_sums.each do |r|
      organisation_id = organisation_id_by_event[r['_id']['event_id']]
      next unless organisation_id

      @rows[organisation_id][:value] += Money.new(r['value'] * 100, r['_id']['currency'])
      @rows[organisation_id][:sold] = true
    end
    @rows.select! { |_, row| row[:sold] }

    @tickets_count = ticket_counts.values.sum
    @total_value = order_sums.sum(Money.new(0, 'GBP')) { |r| Money.new(r['value'] * 100, r['_id']['currency']) }.exchange_to('GBP')
    @organisations = Organisation.and(:id.in => @rows.keys).only(:id, :name, :slug, :created_at, :stripe_customer_id, :contribution_requested_gbp_cache, :contribution_paid_gbp_cache)
    erb :'stats/organisations'
  end

  get '/stats/comments' do
    @comments = Comment.includes(:account, :post).and(:body.ne => nil).order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/comments'
  end

  get '/stats/messages' do
    @messages = Message.includes(:messenger, :messengee).order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/messages'
  end

  get '/stats/openrouter' do
    @generations = OpenRouterGeneration.order('created_at desc').paginate(page: params[:page], per_page: 50)
    erb :'stats/openrouter'
  end

  get '/stats/icons' do
    erb :'stats/icons'
  end

  get '/stats/packages' do
    @tab = %w[gems frontend actions].include?(params[:tab]) ? params[:tab] : 'gems'
    @packages = case @tab
                when 'gems' then fetch_gems
                when 'frontend' then fetch_frontend_dependencies
                else fetch_github_actions
                end
    erb :'stats/packages'
  end

  get '/stats/files' do
    root_path = Padrino.root.to_s
    # Dir.glob skips hidden files and directories (like .git). app/assets/javascripts/ext is vendored code, which isn't ours to keep small
    @files = Dir.glob('**/*.{rb,erb,js}', base: root_path).filter_map do |path|
      file_path = File.join(root_path, path)
      next if path.start_with?('app/assets/javascripts/ext/') || !File.file?(file_path)

      { path: path, size: File.size(file_path), modified: File.mtime(file_path) }
    end

    @files.sort_by! { |f| -f[:size] }
    @total_size = @files.sum { |f| f[:size] }

    erb :'stats/files'
  end

  get '/stats/sentry_spans' do
    @spans = sentry_span_entries
    @span_files_count = @spans.map { |span| span[:file] }.uniq.count
    erb :'stats/sentry_spans'
  end

  get '/stats/transactions' do
    # Only transactions whose p50, p99 or p100 is over a number of seconds, by default p99 over 2
    @percentile = %w[p50 p99 p100].include?(params[:percentile]) ? params[:percentile] : 'p99'
    @min_s = params[:min_s] ? params[:min_s].to_f : 2
    # Leaving out the stats pages themselves, and the WhatsApp webhook
    @summaries = Trace.summary.select do |summary|
      summary[:"#{@percentile}_ms"] > @min_s * 1000 && summary[:name] !~ %r{\A[A-Z]+ /stats(/|\z)} && summary[:name] != 'POST /whatsapp'
    end
    @search_summaries = Trace.search_summary
    erb :'stats/transactions'
  end

  get '/stats/traces' do
    # Sorted in Mongo, as the list is paginated: by duration (slowest first by default), time or spans
    @sort = %w[time spans].include?(params[:sort]) ? params[:sort] : 'duration'
    @sort_dir = params[:dir] == 'asc' ? 'asc' : 'desc'
    @traces = Trace.order({ 'time' => :created_at, 'duration' => :duration_ms, 'spans' => :span_count }[@sort] => @sort_dir)
    @traces = @traces.and(name: params[:name]) if params[:name]
    @traces = @traces.and(xhr: params[:xhr] == '1') if params[:xhr]
    @traces = @traces.slower_than(params[:min_ms].to_f) if params[:min_ms]
    @traces = @traces.only(:name, :status, :http_status, :url, :http_method, :account_id, :xhr, :release, :started_at, :duration_ms, :span_count, :created_at).paginate(page: params[:page], per_page: 50)
    @releases = Trace.releases
    erb :'stats/traces'
  end

  # Deletes the traces of every release committed before the given one
  post '/stats/traces/delete_before' do
    releases = Trace.releases
    before = releases.to_h[params[:release]] || halt(400)
    releases = releases.select { |_release, time| time < before }.map(&:first)
    count = Trace.and(:release.in => releases).delete_all
    flash[:notice] = "Deleted #{pluralize(count, 'trace')} from before #{params[:release][0..6]}"
    redirect '/stats/traces'
  end

  # The slowest trace of a transaction, linked from its p100 on /stats/transactions (and its p99, when that's the
  # same trace). Found on click rather than in Trace.summary, which reads only the index, not the traces' ids
  get '/stats/traces/slowest' do
    traces = Trace.and(name: params[:name])
    traces = traces.and(xhr: params[:xhr] == '1') if params[:xhr]
    trace = traces.order(duration_ms: :desc).only(:_id).first || not_found
    redirect "/stats/traces/#{trace.id}"
  end

  get '/stats/traces/:id' do
    @trace = Trace.find(params[:id]) || not_found
    @span_tree = @trace.span_tree
    erb :'stats/trace'
  end

  get '/stats/routes' do
    route_pattern = /^(\s*)(get|post|put|delete|patch|options|head)\s+['"]([^'"]+)['"]/

    @methods = (Dir.glob(Padrino.root('app/controllers/*.rb')) + [Padrino.root('app/app.rb')]).flat_map do |file_path|
      lines = File.readlines(file_path)
      filename = File.basename(file_path)

      # Find all route starts with their line numbers and indentation
      route_starts = lines.each_with_index.filter_map do |line, idx|
        next unless (match = line.match(route_pattern))

        { name: "#{match[2]} #{match[3]}", indent: match[1].size, start: idx }
      end

      # For each route, find its matching 'end'
      route_starts.map do |route|
        end_line = lines[(route[:start] + 1)..].each_with_index.find do |line, _|
          line.strip == 'end' && line[/\A */].size == route[:indent]
        end&.last

        next unless end_line

        end_idx = route[:start] + 1 + end_line + 1
        { name: route[:name], file: filename, start_line: route[:start] + 1,
          end_line: end_idx, loc: end_idx - route[:start] }
      end.compact
    rescue StandardError
      []
    end.sort_by { |m| -m[:loc] }

    erb :'stats/routes'
  end

  get '/stats/delivery' do
    @period = params[:period] || '24'
    @stats = MailgunDeliveryStats.fetch(period: @period)
    erb :'stats/delivery'
  end

  get '/stats/asns' do
    @hours = 1 * 24

    rows = nil
    country_rows = nil
    threads = [
      Thread.new { @rule = Asn.fetch_rule },
      Thread.new { rows = Asn.fetch_analytics(hours: @hours) },
      Thread.new { country_rows = Asn.fetch_country_data(hours: @hours) }
    ]
    threads.each(&:join)

    @blocked_asns = Asn.blocked_asns(@rule)
    @legit_asns = Asn.legit_asns
    @asn_names = {}
    @asn_countries = {}
    rows.each do |r|
      asn = r.dig('dimensions', 'clientAsn').to_s
      @asn_names[asn] ||= r.dig('dimensions', 'clientASNDescription')
    end
    country_rows.each do |r|
      asn = r.dig('dimensions', 'clientAsn').to_s
      @asn_countries[asn] ||= r.dig('dimensions', 'clientCountryName')
    end
    details = Asn.fetch_asn_details(@blocked_asns)
    details[:countries].each { |asn, country| @asn_countries[asn] ||= country if country }
    details[:names].each { |asn, name| @asn_names[asn] ||= name if name }

    @windows = Asn.all_suspicious_windows(rows: rows, hours: @hours, legit_asns: @legit_asns)

    all_unique_asns = (@windows.flat_map { |w| w[:asns].map { |r| r['asn'].to_s } } + @blocked_asns).uniq
    @bot_pct = Asn.fetch_bot_classifications(all_unique_asns)

    erb :'stats/asns'
  end

  post '/stats/asns/block/:asn' do
    halt 400 unless Asn.block!(params[:asn])
    redirect '/stats/asns'
  end

  post '/stats/asns/unblock/:asn' do
    halt 400 unless Asn.unblock!(params[:asn])
    redirect '/stats/asns'
  end

  post '/stats/asns/legit/:asn' do
    stash = Stash.find_or_create_by(key: 'legit_asns') { |s| s.value = '' }
    legit = stash.value.to_s.split(',').map(&:strip).reject(&:empty?)
    if legit.include?(params[:asn])
      legit.delete(params[:asn])
    else
      legit << params[:asn]
    end
    stash.update(value: legit.join(','))
    redirect '/stats/asns'
  end

  get '/raise' do
    msg = params[:message] || 'test error'
    raise msg unless params[:detail]

    begin
      raise msg
    rescue StandardError => e
      ErrorReporting.capture_exception(e, context: { detail: params[:detail] })
    end
  end

  get '/raise_job' do
    msg = params[:message] || 'Test job error'
    Kernel.delay.raise(msg)
    flash[:notice] = 'Test job enqueued - it will fail when the worker processes it'
    redirect back
  end

  get '/fragments/delete/:q' do
    if params[:q]
      count = Fragment.and(key: /#{Regexp.escape(params[:q])}/i).delete_all
      flash[:notice] = "Deleted #{pluralize(count, 'fragment')}"
    end
    redirect '/'
  end

  get '/geolocate' do
    MaxMinder.reader.city(ip_from_cloudflare).to_json
  rescue StandardError => e
    e.to_s
  end
end
