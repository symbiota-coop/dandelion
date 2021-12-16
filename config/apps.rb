Padrino.configure_apps do
  set :session_secret, ENV['SESSION_SECRET']
end

Padrino.mount('ActivateAdmin::App', app_file: ActivateAdmin.root('app/app.rb')).to('/dadmin')
Padrino.mount('Dandelion::App', app_file: Padrino.root('app/app.rb')).to('/')
