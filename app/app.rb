module Dandelion
  class App < Padrino::Application
    register Padrino::Rendering
    register Padrino::Helpers
    register WillPaginate::Sinatra
    helpers Activate::ParamHelpers
    helpers Activate::NavigationHelpers

    require 'sass/plugin/rack'
    Sass::Plugin.options[:template_location] = Padrino.root('app', 'assets', 'stylesheets')
    Sass::Plugin.options[:css_location] = Padrino.root('app', 'assets', 'stylesheets')
    use Sass::Plugin::Rack

    use Honeybadger::Rack::UserFeedback
    use Honeybadger::Rack::UserInformer
    use Honeybadger::Rack::ErrorNotifier

    use Rack::Session::Cookie, expire_after: 1.year.to_i, secret: ENV['SESSION_SECRET']
    use Rack::UTF8Sanitizer
    use Rack::CrawlerDetect
    use Rack::Attack
    use Dragonfly::Middleware
    use OmniAuth::Builder do
      provider :account
      provider :google_oauth2, ENV['GOOGLE_CLIENT_ID'], ENV['GOOGLE_CLIENT_SECRET'], { image_size: 400 }
      provider :ethereum, { custom_title: 'Sign in with Ethereum' }
    end
    use Rack::Cors do
      allow do
        origins '*'
        resource '*', headers: :any, methods: [:get]
      end
    end
    OmniAuth.config.on_failure = proc { |env|
      OmniAuth::FailureEndpoint.new(env).redirect_to_failure
    }

    set :public_folder, Padrino.root('app', 'assets')
    set :default_builder, 'ActivateFormBuilder'
    set :protection, except: :frame_options

    before do
      @cachebuster = Padrino.env == :development ? SecureRandom.uuid : (ENV['RENDER_GIT_COMMIT'] || ENV['HEROKU_SLUG_COMMIT'])
      redirect "#{ENV['BASE_URI']}#{request.path}#{"?#{request.query_string}" unless request.query_string.blank?}" if ENV['REDIRECT_BASE'] && ENV['BASE_URI'] && (ENV['BASE_URI'] != "#{request.scheme}://#{request.env['HTTP_HOST']}")
      set_time_zone
      fix_params!
      if params[:sign_in_token]
        sign_in_via_token
      elsif params[:api_key]
        sign_in_via_api_key
      end
      PageView.create(path: request.path, query_string: request.query_string) if File.extname(request.path).blank? && !request.xhr? && !request.is_crawler? && !request.path.start_with?('/z/')
      @og_desc = "Find and host #{%w[soulful regenerative metamodern participatory conscious transformative holistic ethical].join(' · ')} events and co-created gatherings"
      @og_image = "#{ENV['BASE_URI']}/images/link.png"
      if current_account
        current_account.set(last_active: Time.now)
        Honeybadger.context({
                              user_id: current_account.id,
                              user_email: current_account.email
                            })
      end
    end

    error do
      Honeybadger.notify(env['sinatra.error'])
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

    get '/' do
      if current_account
        # signed in
        if request.xhr?
          partial :newsfeed, locals: { notifications: current_account.network_notifications.order('created_at desc').paginate(page: params[:page]), include_circle_name: true }
        else
          @body_class = 'greyed'
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

      mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']
      batch_message = Mailgun::BatchMessage.new(mg_client, ENV['MAILGUN_NOTIFICATIONS_HOST'])

      batch_message.from ENV['NOTIFICATIONS_EMAIL_FULL']
      batch_message.subject "[Feedback] #{current_account.name}"
      batch_message.body_text "#{params[:feedback]}\n\nAccount: #{ENV['BASE_URI']}/u/#{current_account.username}\nEmail: #{current_account.email}"
      batch_message.reply_to current_account.email

      batch_message.add_recipient(:to, ENV['FOUNDER_EMAIL'])

      batch_message.finalize if Padrino.env == :production

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
      upload = current_account.uploads.create(file: params[:upload])
      { default: upload.file.url }.to_json
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

    get '/search' do
      if request.xhr?
        @q = params[:term]
        @type = params[:type]
        halt if @q.nil? || @q.length < 3 || @q.length > 200

        model_class = @type ? search_type_to_model(@type) : nil
        perform_ajax_search(@q, model_class).to_json
      else
        detected_type, @q = parse_search_query(params[:q])
        @type = detected_type || params[:type] || 'events'
        model_class = search_type_to_model(@type)

        perform_full_search(@q, model_class) if @q

        erb :search
      end
    end

    get '/theme.css' do
      content_type 'text/css'
      scss_content = File.read(Padrino.root('app/assets/stylesheets/theme.scss'))
      if (theme_color = params[:theme_color])
        theme_color = "##{theme_color}" unless theme_color.start_with?('#')
        # Validate hex color format: # followed by 3 or 6 hexadecimal characters
        scss_content.sub!(/\$theme-color:.*?;/, "$theme-color: #{theme_color};") if theme_color.match?(/\A#[0-9A-Fa-f]{3}\z|\A#[0-9A-Fa-f]{6}\z/)
      end
      Sass::Engine.new(scss_content, syntax: :scss).render
    end
  end
end
