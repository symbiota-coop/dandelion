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

    use Rack::Session::Cookie, expire_after: 1.year.to_i, secret: ENV['SESSION_SECRET']
    use Rack::UTF8Sanitizer
    use Rack::CrawlerDetect
    use RackSessionAccess::Middleware if Padrino.env == :test
    use Dragonfly::Middleware
    use OmniAuth::Builder do
      provider :account
      provider :ethereum, { custom_title: 'Sign in with Ethereum' }
      provider :google_oauth2, ENV['GOOGLE_CLIENT_ID'], ENV['GOOGLE_CLIENT_SECRET'], { image_size: 400 }
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
      begin
        Time.zone = if current_account && current_account.time_zone
                      current_account.time_zone
                    elsif session[:time_zone]
                      session[:time_zone]
                    # elsif request.location && request.location.data['timezone']
                    #   session[:time_zone] = request.location.data['timezone']
                    else
                      ENV['DEFAULT_TIME_ZONE']
                    end
      rescue StandardError
        Time.zone = ENV['DEFAULT_TIME_ZONE']
      end
      fix_params!
      @_params = params; # force controllers to inherit the fixed params
      def params
        @_params
      end
      if params[:sign_in_token]
        if (account = Account.find_by(sign_in_token: params[:sign_in_token]))
          flash.now[:notice] = 'Signed in via a code/link'
          account.update_attribute(:failed_sign_in_attempts, 0)
          account.sign_ins.create(env: env_yaml, skip_increment: %w[unsubscribe give_feedback subscriptions].any? { |p| request.path.include?(p) })
          if account.sign_ins_count == 1
            account.set(email_confirmed: true)
            account.send_activation_notification
          end
          session[:account_id] = account.id.to_s
          account.update_attribute(:sign_in_token, SecureRandom.uuid)
        elsif !current_account
          kick! notice: "That sign in code/link isn't valid any longer. Please request a new one."
        end
      elsif params[:api_key]
        if (account = Account.find_by(api_key: params[:api_key]))
          session[:account_id] = account.id.to_s
        elsif !current_account
          403
        end
      end
      PageView.create(path: request.path, query_string: request.query_string) if File.extname(request.path).blank? && !request.xhr? && !request.is_crawler?
      @og_desc = 'Find and host regenerative events and co-created gatherings 🧘🏼‍♀️ 🌱 🕺'
      @og_image = "#{ENV['BASE_URI']}/images/cover2.jpg"
      current_account.set(last_active: Time.now) if current_account
    end

    error do
      Airbrake.notify(env['sinatra.error'],
                      url: "#{ENV['BASE_URI']}#{request.path}",
                      current_account: (JSON.parse(current_account.to_json) if current_account),
                      params: params,
                      request: request.env.select { |_k, v| v.is_a?(String) },
                      session: session)
      if content_type == :html
        erb :error, layout: :application
      else
        500
      end
    end

    get '/error' do
      erb :error, layout: :application
    end

    not_found do
      if content_type == :html
        erb :not_found, layout: :application
      else
        404
      end
    end

    get '/not_found' do
      erb :not_found, layout: :application
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

    get '/' do
      if current_account
        if request.xhr?
          partial :newsfeed, locals: { notifications: current_account.network_notifications.order('created_at desc').page(params[:page]), include_circle_name: true }
        else
          erb :home_signed_in
        end
      else
        @from = Date.today
        @events = Event.live.public.legit.future(@from)
        @accounts = []
        @places = Place.all.order('created_at desc')
        if request.xhr?
          400
        else
          erb :home_not_signed_in
        end
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
      current_account.update_attribute(:last_checked_notifications, Time.now)
      200
    end

    post '/checked_messages' do
      sign_in_required!
      current_account.update_attribute(:last_checked_messages, Time.now)
      200
    end

    get '/network', provides: :json do
      sign_in_required!
      if (@q = params[:q])
        current_account.network.and(:id.in => search_accounts(@q).pluck(:id)).map do |account|
          { key: account.name, value: account.username }
        end.to_json
      end
    end

    get '/birthdays' do
      sign_in_required!
      @account_ids = current_account.following.ids_by_next_birthday
      @account_ids = @account_ids.paginate(page: params[:page], per_page: 20)
      erb :birthdays
    end

    get '/notifications/:id' do
      admins_only!
      @notification = Notification.find(params[:id]) || not_found
      erb :'emails/notification', locals: { notification: @notification, circle: @notification.circle }, layout: false
    end

    post '/upload' do
      sign_in_required!
      upload = current_account.uploads.create(file: params[:upload])
      { default: upload.file.url }.to_json
    end

    get '/donate' do
      erb :donate
    end

    get '/code' do
      erb :code
    end

    get '/token' do
      erb :token
    end

    get '/films' do
      @title = 'Films'
      erb :'films/films'
    end

    get '/substack_opt_in' do
      sign_in_required!
      current_account.update_attribute(:substack_opt_in, Time.now)
      erb :substack_opt_in
    end
  end
end
