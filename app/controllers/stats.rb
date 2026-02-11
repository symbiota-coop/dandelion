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

  get '/stats/feedback' do
    @event_feedbacks = EventFeedback.includes(:account, event: :organisation).order('created_at desc')
    @event_feedbacks = @event_feedbacks.and(:id.in => search(EventFeedback, @event_feedbacks, params[:q], 25).map(&:id)) if params[:q]
    @event_feedbacks = @event_feedbacks.and(:rating.ne => 5) if params[:hide_5_stars]
    erb :'stats/feedback'
  end

  get '/stats/orders' do
    @orders = Order.includes(:account, :event, :revenue_sharer, :discount_code).order('created_at desc')
    erb :'stats/orders'
  end

  get '/stats/organisations' do
    @from = params[:from] ? parse_date(params[:from]) : Date.new(3.months.ago.year, 3.months.ago.month, 1)
    @to = params[:to] ? parse_date(params[:to]) : Date.new(Date.today.year, Date.today.month, 1) - 1.day
    @min_tickets = params[:min_tickets] ? params[:min_tickets].to_i : 10
    @min_order_value = params[:min_order_value] || 1000
    erb :'stats/organisations'
  end

  get '/stats/comments' do
    @comments = Comment.includes(:account, :post).and(:body.ne => nil).order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/comments'
  end

  get '/stats/accounts' do
    @accounts = Account.includes(organisationships: :organisation, memberships: :gathering, mapplications: :gathering).public.order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/accounts'
  end

  get '/stats/messages' do
    @messages = Message.includes(:messenger, :messengee).order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/messages'
  end

  get '/stats/icons' do
    erb :'stats/icons'
  end

  get '/stats/frontend_dependencies' do
    @dependencies = []
    mutex = Mutex.new
    threads = []

    FRONTEND_DEPENDENCIES.each do |base_url, libs|
      # Skip local files
      next if base_url.start_with?('/')

      libs.each do |path, files|
        threads << Thread.new do
          dep = fetch_frontend_dependency(base_url, path)
          if dep
            # Build file URLs for size calculation
            file_urls = files.split.map do |f|
              path.nil? ? "#{base_url}#{f}" : "#{base_url}#{path}/#{f}"
            end
            dep[:file_urls] = file_urls
            mutex.synchronize { @dependencies << dep }
          end
        end
      end
    end

    threads.each(&:join)

    # Sort by date (oldest first, nils at top)
    @dependencies.sort_by! { |d| d[:release_date] || d[:commit_date] || Time.at(0) }

    erb :'stats/frontend_dependencies'
  end

  get '/stats/gems' do
    @gems = []
    mutex = Mutex.new
    threads = []

    gemfile_content = File.read(Padrino.root('Gemfile'))

    # Extract gem names (excluding GitHub gems which won't be on RubyGems)
    gem_names = []
    gemfile_content.each_line do |line|
      next if line.strip.start_with?('#')
      next if line.include?('github:')

      gem_names << Regexp.last_match(1) if line =~ /gem ['"]([^'"]+)['"]/
    end
    gem_names.uniq!

    gem_names.each do |gem_name|
      threads << Thread.new do
        gem_info = fetch_gem_info(gem_name)
        mutex.synchronize { @gems << gem_info }
      end
    end

    threads.each(&:join)

    # Sort by last updated (oldest first to highlight outdated gems, nils at top)
    @gems.sort_by! { |g| g[:updated_at] || Time.at(0) }

    erb :'stats/gems'
  end

  get '/stats/files' do
    # Read repomix config to get ignore patterns
    config_path = Padrino.root('repomix.config.json')
    ignore_patterns = []
    if File.exist?(config_path)
      config = JSON.parse(File.read(config_path))
      ignore_patterns = config.dig('ignore', 'customPatterns') || []
    end

    @files = []
    root_path = Padrino.root.to_s

    # Traverse all files
    Find.find(root_path) do |file_path|
      # Skip hidden directories entirely (like .git)
      Find.prune if File.directory?(file_path) && File.basename(file_path).start_with?('.')
      next unless File.file?(file_path)

      # Get relative path from root
      relative_path = file_path.sub("#{root_path}/", '')
      # Handle root-level files
      relative_path = File.basename(file_path) if relative_path == file_path

      # Check if file matches any ignore pattern
      # FNM_PATHNAME: wildcards don't match /
      # FNM_EXTGLOB: enables ** (globstar) to match directories recursively
      fnmatch_flags = File::FNM_PATHNAME | File::FNM_EXTGLOB
      ignored = ignore_patterns.any? do |pattern|
        # Convert glob pattern to match relative paths
        # Handle both relative and absolute path matching
        File.fnmatch?(pattern, relative_path, fnmatch_flags) ||
          File.fnmatch?(pattern, file_path, fnmatch_flags) ||
          File.fnmatch?("#{root_path}/#{pattern}", file_path, fnmatch_flags)
      end

      next if ignored

      # Only show .rb, .erb, and .js files
      next unless ['.rb', '.erb', '.js'].include?(File.extname(file_path))

      file_size = File.size(file_path)
      @files << {
        path: relative_path,
        size: file_size,
        modified: File.mtime(file_path)
      }
    end

    # Sort by size (largest first)
    @files.sort_by! { |f| -f[:size] }
    @total_size = @files.sum { |f| f[:size] }

    erb :'stats/files'
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

  get '/stats/asns' do
    @days = 3

    rows = nil
    country_rows = nil
    threads = [
      Thread.new { @rule = Asn.fetch_rule },
      Thread.new { rows = Asn.fetch_analytics(days: @days) },
      Thread.new { country_rows = Asn.fetch_country_data(days: @days) }
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

    @windows = Asn.suspicious_windows(rows: rows, days: @days, legit_asns: @legit_asns)

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

  ###

  get '/raise' do
    msg = params[:message] || 'test error'
    raise msg unless params[:detail]

    begin
      raise msg
    rescue StandardError => e
      Honeybadger.context({ detail: params[:detail] })
      Honeybadger.notify(e)
    end
  end

  get '/raise_job' do
    msg = params[:message] || 'Test job error'
    Delayed::Job.enqueue TestJob.new(message: msg)
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
    MaxMind::GeoIP2::Reader.new(database: 'GeoLite2-City.mmdb').city(ip_from_cloudflare).to_json
  rescue StandardError => e
    e.to_s
  end
end
