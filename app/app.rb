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

    use Rack::UTF8Sanitizer
    use RackSessionAccess::Middleware if Padrino.env == :test
    use Dragonfly::Middleware
    use OmniAuth::Builder do
      provider :account
      provider :ethereum
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

    set :sessions, expire_after: 1.year
    set :public_folder, Padrino.root('app', 'assets')
    set :default_builder, 'ActivateFormBuilder'
    set :protection, except: :frame_options

    before do
      @cachebuster = Padrino.env == :development ? SecureRandom.uuid : ENV['HEROKU_SLUG_COMMIT']
      redirect "#{ENV['BASE_URI']}#{request.path}" if ENV['BASE_URI'] && (ENV['BASE_URI'] != "#{request.scheme}://#{request.env['HTTP_HOST']}")
      begin
        Time.zone = if current_account && current_account.time_zone
                      current_account.time_zone
                    elsif session[:time_zone]
                      session[:time_zone]
                    else
                      'London'
                    end
      rescue StandardError
        Time.zone = 'London'
      end
      fix_params!
      @_params = params; # force controllers to inherit the fixed params
      def params
        @_params
      end
      if params[:sign_in_token]
        if (account = Account.find_by(sign_in_token: params[:sign_in_token]))
          flash.now[:notice] = 'Signed in via a link'
          account.update_attribute(:failed_sign_in_attempts, 0)
          account.sign_ins.create(env: env_yaml, skip_increment: %w[unsubscribe give_feedback subscriptions].any? { |p| request.path.include?(p) })
          if account.sign_ins_count == 1
            account.set(email_confirmed: true)
            account.send_activation_notification
          end
          session[:account_id] = account.id.to_s
          account.update_attribute(:sign_in_token, SecureRandom.uuid)
        elsif !current_account
          kick! notice: 'Please sign in or <a href="/accounts/sign_in_link">get a sign in link</a> to continue.'
        end
      end
      @og_desc = 'Dandelion is a platform for ticketed events and co-created gatherings created by the not-for-profit worker co-operative Dandelion Collective'
      @og_image = "#{ENV['BASE_URI']}/images/black-on-white-link.png"
      @no_discord = true if params[:minimal]
      current_account.set(last_active: Time.now) if current_account
    end

    error do
      Airbrake.notify(env['sinatra.error'],
                      url: "#{ENV['BASE_URI']}#{request.path}",
                      current_account: (JSON.parse(current_account.to_json) if current_account),
                      params: params,
                      request: request.env.select { |_k, v| v.is_a?(String) },
                      session: session)
      erb :error, layout: :application
    end

    get '/time_zone' do
      session[:set_time_zone] = true
      session[:time_zone] = params[:time_zone]
      redirect back
    end

    get '/activities/5f3ab46e866bcd0015deb3cb' do
      redirect '/o/the-psychedelic-society/members'
    end

    get '/error' do
      erb :error, layout: :application
    end

    not_found do
      erb :not_found, layout: :application
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
        @hide_right_nav = true
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
      current_account.update_attribute(:last_checked_notifications, Time.now)
      200
    end

    post '/checked_messages' do
      sign_in_required!
      current_account.update_attribute(:last_checked_messages, Time.now)
      200
    end

    get '/search' do
      sign_in_required!
      @type = params[:type] || 'accounts'
      if (@q = params[:q])
        case @type
        when 'gatherings'
          @gatherings = Gathering.and(name: /#{::Regexp.escape(@q)}/i).and(listed: true).and(:privacy.ne => 'secret')
          @gatherings = @gatherings.paginate(page: params[:page], per_page: 10).order('name asc')
        when 'places'
          @places = Place.and(name: /#{::Regexp.escape(@q)}/i)
          @places = @places.paginate(page: params[:page], per_page: 10).order('name asc')
        when 'organisations'
          @organisations = Organisation.and(name: /#{::Regexp.escape(@q)}/i)
          @organisations = @organisations.paginate(page: params[:page], per_page: 10).order('name asc')
        when 'events'
          redirect "/events?q=#{@q}"
        else
          @accounts = Account.public
          @accounts = @accounts.and(:id.in => Account.all.or(
            { name: /#{::Regexp.escape(@q)}/i },
            { name_transliterated: /#{::Regexp.escape(@q)}/i },
            { email: @q.downcase },
            { username: /#{::Regexp.escape(@q)}/i }
          ).pluck(:id))
          @accounts = @accounts.paginate(page: params[:page], per_page: 10).order('last_active desc')
        end
      end
      erb :search
    end

    get '/network', provides: :json do
      sign_in_required!
      if (@q = params[:q])
        current_account.network.and(:id.in => Account.all.or(
          { name: /#{::Regexp.escape(@q)}/i },
          { name_transliterated: /#{::Regexp.escape(@q)}/i },
          { email: @q.downcase },
          { username: /#{::Regexp.escape(@q)}/i }
        ).pluck(:id)).map do |account|
          { key: account.name, value: account.username }
        end.to_json
      end
    end

    get '/notifications/:id' do
      admins_only!
      @notification = Notification.find(params[:id]) || not_found
      erb :'emails/notification', locals: { notification: @notification, circle: @notification.circle }, layout: false
    end

    post '/upload' do
      sign_in_required!
      upload = current_account.uploads.create(file: params[:upload])
      { url: upload.file.url }.to_json
    end

    get '/donate' do
      erb :donate
    end

    get '/qr/:id', provides: :png do
      RQRCode::QRCode.new(params[:id]).as_png(border_modules: 0, module_px_size: 5).to_blob
    end

    get '/graph' do
      erb :graph
    end
  end
end
