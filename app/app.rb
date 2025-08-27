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
    use RackSessionAccess::Middleware if Padrino.env == :test
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
      @og_image = "#{ENV['BASE_URI']}/images/link.jpg"
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

    get '/raise' do
      admins_only!
      msg = params[:message] || 'test error'
      raise msg unless params[:detail]

      begin
        raise msg
      rescue StandardError => e
        Honeybadger.context({ detail: params[:detail] })
        Honeybadger.notify(e)
      end
    end

    not_found do
      content_type 'text/html'
      erb :not_found, layout: :application
    end

    get '/not_found' do
      erb :not_found, layout: :application
    end

    ###

    get '/fragments/delete/:q' do
      admins_only!
      if params[:q]
        count = Fragment.and(key: /#{Regexp.escape(params[:q])}/i).delete_all
        flash[:notice] = "Deleted #{pluralize(count, 'fragment')}"
      end
      redirect '/'
    end

    get '/geolocate' do
      admins_only!
      MaxMind::GeoIP2::Reader.new(database: 'GeoLite2-City.mmdb').city(ip_from_cloudflare).to_json
    rescue StandardError => e
      e.to_s
    end

    ###

    get '/' do
      if current_account
        if request.xhr?
          partial :newsfeed, locals: { notifications: current_account.network_notifications.order('created_at desc').page(params[:page]), include_circle_name: true }
        else
          erb :home_signed_in
        end
      else
        @from = Date.today
        @no_content_padding_bottom = true
        @accounts = []
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
      StripeRowSplitter.split(File.read(params[:csv]))
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
  end
end
