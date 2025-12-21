Dandelion::App.controller do
  before do
    admins_only!
  end

  get '/stats/llms' do
    response = Faraday.get('https://artificialanalysis.ai/models') do |req|
      req.headers['RSC'] = '1'
    end
    body = response.body.force_encoding('UTF-8').scrub

    # Extract the models array from the RSC response
    # The models are embedded in the React Server Components payload
    models_match = body.match(/"models":\[(\{.+?\})\],"model_url"/)
    if models_match
      # Find the full models array by locating its boundaries
      start_idx = body.index('"models":[') + 9
      # Count brackets to find the end of the array
      bracket_count = 0
      end_idx = start_idx
      body[start_idx..].each_char.with_index do |char, idx|
        bracket_count += 1 if char == '['
        bracket_count -= 1 if char == ']'
        if bracket_count.zero?
          end_idx = start_idx + idx
          break
        end
      end
      models_json = body[start_idx..end_idx]
      @models = JSON.parse(models_json)
    else
      @models = []
    end

    # Calculate cost to run for each model using primary provider
    @models.each do |model|
      token_counts = model['intelligence_index_token_counts']
      host_models = model['host_models']
      primary_host_id = model['computed_performance_host_model_id']
      next unless token_counts && host_models&.any?

      input_tokens = token_counts['input_tokens'] || 0
      output_tokens = token_counts['output_tokens'] || 0

      # Use primary host model (same as AA site uses for their calculations)
      # Fallback: use most common price tier when no primary is set
      host = host_models.find { |hm| hm['id'] == primary_host_id }
      unless host
        non_free = host_models.select { |hm| (hm['price_1m_blended_3_to_1'] || 0) > 0 }
        most_common_price = non_free.group_by { |hm| hm['price_1m_blended_3_to_1'].round(4) }
                                    .max_by { |_price, providers| providers.size }
                                    &.first
        host = non_free.find { |hm| hm['price_1m_blended_3_to_1'].round(4) == most_common_price } if most_common_price
      end
      next unless host && host['price_1m_input_tokens'] && host['price_1m_output_tokens']

      input_cost = input_tokens / 1_000_000.0 * host['price_1m_input_tokens']
      output_cost = output_tokens / 1_000_000.0 * host['price_1m_output_tokens']
      model['cost_to_run'] = input_cost + output_cost
    end

    erb :'stats/llms'
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

  get '/stats/gems' do
    @gems = []
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
      response = Faraday.get("https://rubygems.org/api/v1/gems/#{gem_name}.json")
      if response.status == 200
        data = JSON.parse(response.body)
        @gems << {
          name: data['name'],
          version: data['version'],
          updated_at: Time.parse(data['version_created_at']),
          downloads: data['downloads'],
          homepage: data['homepage_uri'],
          source_code: data['source_code_uri'],
          info: data['info']&.to_s&.split('.')&.first
        }
      else
        @gems << { name: gem_name, version: nil, updated_at: nil, downloads: nil, homepage: nil, source_code: nil, info: nil }
      end
    rescue StandardError
      @gems << { name: gem_name, version: nil, updated_at: nil, downloads: nil, homepage: nil, source_code: nil, info: nil }
    end

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
