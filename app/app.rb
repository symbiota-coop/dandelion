module Dandelion
  class App < Padrino::Application
    register Padrino::Rendering
    register Padrino::Helpers
    register WillPaginate::Sinatra
    helpers ParamHelpers
    helpers NavigationHelpers

    use Sentry::Rack::CaptureExceptions

    # Via :sessions (not `use`) so the session sits inside Rack::Protection and its origin checks can drop it
    set :sessions, expire_after: 1.year.to_i, same_site: :lax, secure: Padrino.env == :production
    use Rack::UTF8Sanitizer
    use Rack::CrawlerDetect
    use Rack::Attack
    use Dragonfly::Middleware
    use OmniAuth::Builder do
      provider :account
      provider :google_oauth2, ENV['GOOGLE_CLIENT_ID'], ENV['GOOGLE_CLIENT_SECRET'], { image_size: 400 }
      provider :ethereum
      provider :atproto,
               "#{ENV['BASE_URI']}/atproto/oauth-client-metadata.json",
               nil,
               scope: 'atproto',
               private_key: AtprotoKeyManager.current_private_key,
               client_jwk: AtprotoKeyManager.current_jwk,
               setup: AtprotoSetup.setup_proc
    end
    use Rack::Cors do
      allow do
        origins '*'
        resource '*', headers: :any, methods: [:get]
      end
      allow do
        origins '*'
        resource '/mcp', headers: :any, methods: [:get, :post, :delete]
      end
    end
    OmniAuth.config.on_failure = proc { |env|
      OmniAuth::FailureEndpoint.new(env).redirect_to_failure
    }

    set :public_folder, Padrino.root('app', 'assets')

    # Versioned asset URLs (cachebust's ?digest) never change, so browsers and Cloudflare may keep them for a year.
    # Only when the digest is this file's: mid-deploy, a page from the new instance can ask the old one for
    # app.js?<new digest>, and the old file must not be kept under the new URL. Nor is a 404 ever kept
    def static!(options = {})
      if !request.query_string.empty? && static_file?(request.path_info)
        if request.query_string == asset_digest(request.path_info)
          cache_control :public, :immutable, max_age: 1.year.to_i
        else
          cache_control :no_store
        end
      end
      super
    end
    set :default_builder, 'BootstrapFormBuilder'
    set :protection, except: :frame_options

    before do
      # Health checks hit the instance directly, so they must skip the BASE_URI redirect (and page views)
      next if ['/mcp', '/health'].include?(request.path)

      redirect "#{ENV['BASE_URI']}#{request.fullpath}" if ENV['REDIRECT_BASE'] && ENV['BASE_URI'] && (ENV['BASE_URI'] != "#{request.scheme}://#{request.env['HTTP_HOST']}")
      set_time_zone
      fix_params!
      Sentry.set_tags(xhr: request.xhr? ? 'true' : 'false')
      # XHR responses are pagelets and partials that must be fresh, and often share a URL with the full page,
      # so the browser mustn't store them (a stored partial could be shown in place of the page on back navigation)
      cache_control :no_store if request.xhr?
      if params[:sign_in_token]
        sign_in_via_token
      elsif params[:api_key] && request.path.match?(%r{\A/z(/|\.|\z)})
        sign_in_via_api_key
      end
      PageView.create(request: request) if !request.head? && File.extname(request.path).blank? && !request.xhr? && !request.is_crawler? && !request.path.start_with?('/z/')
      @og_desc = "Find and host #{ADJECTIVES.join(' · ')} events and co-created gatherings"
      @og_image = "#{ENV['BASE_URI']}/images/link.png"
      if current_account
        # Pagelets and polls are XHR, so skipping them saves a write on most requests; page loads keep it current
        current_account.set(last_active: Time.now) unless request.xhr?
        Sentry.set_user(id: current_account.id.to_s, email: current_account.email)
      end
    end

    after do
      unless @embeddable
        response['X-Frame-Options'] = 'SAMEORIGIN'
        response['Content-Security-Policy'] ||= "frame-ancestors 'self'"
      end

      route = request.route_obj
      next unless route

      route_path = route.original_path.to_s.sub(/\(\.:format\)\?\z/, '')
      name = "#{request.request_method} #{route_path}"

      ext = File.extname(request.path)
      name = "#{name}#{ext}" if !ext.empty? && !name.end_with?(ext)

      scope = Sentry.get_current_scope
      scope&.set_transaction_name(name, source: :route)
      scope&.get_transaction&.set_name(name, source: :route)
    end

    error do
      erb :error, layout: :application
    end

    get '/error' do
      erb :error, layout: :application
    end

    not_found do
      content_type 'text/html'
      erb :not_found, layout: :application
    end

    get '/not_found' do
      erb :not_found, layout: :application
    end

    ###

    head '/' do
      200
    end

    # Render's health check: only route traffic to an instance once it's serving
    get '/health' do
      200
    end

    get '/' do
      if current_account
        # signed in
        if request.xhr?
          notifications = current_account.network_notifications.includes(:circle, :notifiable).order('created_at desc').paginate(page: params[:page])
          partial :newsfeed, locals: { notifications: notifications, include_circle_name: true }
        else
          @body_class = 'canvas'
          erb :home_signed_in
        end
      elsif request.xhr?
        # not signed in
        400
      else
        @from = Date.today
        @events_search_order = 'trending'
        @no_content_padding_bottom = true
        @accounts = []
        erb :home_not_signed_in
      end
    end

    post '/sidebar' do
      session[:sidebar_minified] = params[:minified] == 'true' ? 'minified' : 'unminified'
      { sidebar_minified: session[:sidebar_minified] }.to_json
    end

    get '/notifications' do
      sign_in_required!
      if request.xhr?
        cp(:notifications, key: "/notifications?account_id=#{current_account.id}", expires: 1.minute.from_now)
      else
        redirect '/'
      end
    end

    post '/checked_notifications' do
      sign_in_required!
      Fragment.find_by(key: "/notifications?account_id=#{current_account.id}").try(:destroy)
      current_account.set(last_checked_notifications: Time.now)
      200
    end

    post '/checked_messages' do
      sign_in_required!
      current_account.set(last_checked_messages: Time.now)
      200
    end

    get '/feedback' do
      @sent = true
      partial :feedback
    end

    post '/feedback' do
      sign_in_required!
      halt 400 unless params[:feedback]

      EmailHelper.send_to_founder(
        subject: "[Feedback] #{current_account.name}",
        body_text: [
          params[:feedback],
          '',
          "Account: #{ENV['BASE_URI']}/u/#{current_account.username}",
          "Email: #{current_account.email}"
        ].join("\n"),
        reply_to: current_account.email
      )

      200
    end

    get '/network', provides: :json do
      sign_in_required!
      if (@q = params[:q])
        @accounts = current_account.network
        @accounts = @accounts.and(:id.in => Account.search(@q, @accounts).pluck(:id))
        @accounts.map do |account|
          { key: account.name, value: account.username }
        end.to_json
      end
    end

    get '/birthdays', provides: [:html, :ics] do
      sign_in_via_ics_key if content_type == :ics
      sign_in_required!
      case content_type
      when :html
        @account_ids = current_account.following.ids_by_next_birthday
        @account_ids = @account_ids.paginate(page: params[:page], per_page: 20)
        erb :birthdays
      when :ics
        cal = Icalendar::Calendar.new
        cal.append_custom_property('X-WR-CALNAME', 'Birthdays')
        current_account.following.each do |account|
          next unless account.date_of_birth

          cal.event do |e|
            e.summary = "#{account.name}'s #{(account.age + 1).ordinalize} birthday"
            e.dtstart = Icalendar::Values::Date.new(account.next_birthday.to_date)
            e.description = %(#{ENV['BASE_URI']}/u/#{account.username})
            e.uid = account.id.to_s
          end
        end
        cal.to_ical
      end
    end

    post '/upload' do
      sign_in_required!
      upload = current_account.uploads.new(file: params[:upload])
      halt 422, { error: { message: 'Only images can be uploaded' } }.to_json unless upload.file&.image?
      upload.save
      halt 422, { error: { message: 'Upload failed' } }.to_json unless upload.persisted?
      { default: upload.file.url }.to_json
    end

    get '/referrals' do
      sign_in_required!
      @organisations = current_account.organisations_as_referrer
      erb :referrals
    end

    post '/referrals/:id/claim' do
      sign_in_required!
      @organisation = current_account.organisations_as_referrer.find(params[:id]) || not_found
      revenue = @organisation.referral_revenue

      halt 400 if revenue < Organisation::REFERRAL_REWARD_THRESHOLD || @organisation.reward_claimer_id.present?

      mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
      batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

      batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
      batch_message.subject "[Reward claim] #{current_account.name} for #{@organisation.name}"
      batch_message.body_text [
        "Reward claimer: #{ENV['BASE_URI']}/u/#{current_account.username}",
        "Referrer: #{@organisation.referrer ? "#{ENV['BASE_URI']}/u/#{@organisation.referrer.username}" : '—'}",
        "Organisation: #{ENV['BASE_URI']}/o/#{@organisation.slug}",
        "Total revenue: #{m(revenue, 'EUR')}"
      ].join("\n")

      Account.and(admin: true).each do |account|
        batch_message.add_recipient(:to, account.email, { 'firstname' => account.firstname || 'there', 'token' => account.sign_in_token_for_email, 'id' => account.id.to_s })
      end

      batch_message.finalize if Padrino.env == :production

      @organisation.set(reward_claimer_id: current_account.id)

      flash[:notice] = "Your referral reward claim has been submitted, and we'll be in touch soon."
      redirect '/referrals'
    end

    get '/stripe_row_splitter' do
      erb :stripe_row_splitter
    end

    post '/stripe_row_splitter', provides: :csv do
      halt 400 unless params[:csv].is_a?(Tempfile)
      StripeRowSplitter.split(File.read(params[:csv].path))
    end

    get '/donate' do
      erb :donate
    end

    get '/code' do
      erb :'code/code'
    end

    get '/privacy' do
      erb :privacy
    end

    get '/cookies' do
      erb :cookies
    end

    get '/terms' do
      erb :terms
    end

    get '/contact' do
      erb :contact
    end

    get '/design' do
      @title = 'Design guide'
      @og_image = "#{ENV['BASE_URI']}/images/design.png"
      @og_desc = 'The visual language of Dandelion: colour, type, spacing and components, rendered from the live CSS'
      erb :design
    end

    get '/features' do
      @no_content_padding_bottom = true
      @title = 'Features'
      @og_image = "#{ENV['BASE_URI']}/images/features.png"
      erb :features
    end

    get '/dandelion-vs-luma' do
      @no_content_padding_bottom = true
      @title = 'Dandelion vs Luma'
      @og_image = "#{ENV['BASE_URI']}/images/dandelion_vs_luma.png"
      @og_desc = "Here's why organisers are choosing a fee-free, co-op-run alternative with a transparent reputation system"
      erb :dandelion_vs_luma
    end

    get '/search' do
      if request.xhr?
        @type = params[:type]
        @q = params[:term]
        halt if @q.nil? || @q.length < 3 || @q.length > 200
        model_class = @type ? search_type_to_model(@type) : nil
        perform_ajax_search(@q, model_class).to_json
      else
        detected_type, @q = parse_search_query(params[:q])
        @type = detected_type || params[:type] || 'events'
        model_class = search_type_to_model(@type)
        perform_full_search(@q, model_class)
        erb :search
      end
    end

    %w[get post delete].each do |method|
      send(method, '/mcp') do
        status, headers, body = Dandelion::MCP.handle_http_request(request)
        [status, headers, body]
      end
    end

    get '/theme.css' do
      content_type 'text/css'
      theme_color = DEFAULT_THEME_COLOR
      if params[:theme_color]
        requested = params[:theme_color].start_with?('#') ? params[:theme_color] : "##{params[:theme_color]}"
        # Validate hex color format: # followed by 3 or 6 hexadecimal characters
        theme_color = clamp_color(requested) if requested.match?(/\A#[0-9A-Fa-f]{3}\z|\A#[0-9A-Fa-f]{6}\z/)
      end
      ":root {\n  #{theme_css_variables(theme_color)}\n}"
    end
  end
end
