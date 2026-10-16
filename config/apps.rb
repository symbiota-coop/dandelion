Padrino.configure_apps do
  set :session_secret, ENV['SESSION_SECRET']
end

# Around the whole router rather than `use` in the app, where Sinatra's own middleware (MethodOverride) would read the body first
Padrino.use Rack::UTF8Sanitizer

Padrino.mount('Dandelion::App', app_file: Padrino.root('app/app.rb')).to('/')
