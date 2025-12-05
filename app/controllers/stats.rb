Dandelion::App.controller do
  before do
    admins_only!
  end

  get '/stats/charts' do
    erb :'stats/charts'
  end

  get '/stats/feedback' do
    @event_feedbacks = EventFeedback.order('created_at desc')
    @event_feedbacks = @event_feedbacks.and(:id.in => search(EventFeedback, @event_feedbacks, params[:q], 25).map(&:id)) if params[:q]
    @event_feedbacks = @event_feedbacks.and(:rating.ne => 5) if params[:hide_5_stars]
    erb :'stats/feedback'
  end

  get '/stats/orders' do
    @orders = Order.order('created_at desc')
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
    @comments = Comment.and(:body.ne => nil).order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/comments'
  end

  get '/stats/accounts' do
    @accounts = Account.public.order('created_at desc').paginate(page: params[:page], per_page: 20)
    erb :'stats/accounts'
  end

  get '/stats/messages' do
    @messages = Message.order('created_at desc').paginate(page: params[:page], per_page: 20)
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
