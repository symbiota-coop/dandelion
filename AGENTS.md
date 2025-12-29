# Files in lib

Files in lib are auto-loaded by Padrino.load!. No explicit require is necessary.

# MongoDB indexes

Please note that MongoDB indexes are created directly in the database, and are not exhaustively defined in model files.

# Tests

Use the following command structure to test a single file:

`foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb`

# Dependencies

## Gemfile

```
source 'https://rubygems.org'

ruby '3.4.7'
gem 'activesupport'
gem 'irb'
gem 'padrino'
gem 'puma'
gem 'rack'
gem 'rake'
gem 'sass'
gem 'sinatra'

# Admin
gem 'activate-admin', github: 'stephenreid321/activate-admin'
gem 'activate-tools', github: 'stephenreid321/activate-tools'
gem 'will_paginate', github: 'mislav/will_paginate'

# Data storage
gem 'activemodel'
gem 'delayed_job_mongoid'
gem 'dragonfly'
gem 'dragonfly-s3_data_store'
gem 'mongoid'
gem 'mongoid_paranoia'

# Authentication
gem 'bcrypt'
gem 'bech32'
gem 'omniauth'
gem 'omniauth-ethereum', github: 'q9f/omniauth-ethereum.rb'
gem 'omniauth-google-oauth2'
gem 'strong_password'

# Validation and testing
gem 'better_html'
gem 'email_address'
gem 'erb_lint', require: false
gem 'factory_bot'
gem 'rubocop'
group :test do
  gem 'capybara'
  gem 'cuprite'
  gem 'minitest-rg'
end

# Interacting with other websites
gem 'airrecord'
gem 'faraday'
gem 'ferrum', '~> 0.14.0' # scroll behaviour changed in 0.15
gem 'honeybadger'
gem 'jwt'
gem 'maxmind-geoip2'
gem 'mechanize'
gem 'octokit'
gem 'ruby-openai'
gem 'yt'

# Payments
gem 'coinbase_commerce_client'
gem 'eu_central_bank'
gem 'gocardless_pro'
gem 'money'
gem 'money-uphold-bank', github: 'stephenreid321/money-uphold-bank'
gem 'patreon'
gem 'stripe'

# Mail
gem 'incoming'
gem 'mail'
gem 'mailgun-ruby', require: 'mailgun'
gem 'premailer'

# Prawn (PDFs)
gem 'prawn', github: 'prawnpdf/prawn'
gem 'prawn-qrcode'
gem 'prawn-table'
gem 'rqrcode'

# Time
gem 'icalendar'
gem 'timezone'
gem 'tzinfo-data'

# Geography
gem 'countries'
gem 'geocoder'

# Formatting
gem 'addressable'
gem 'html_truncator'
gem 'redcarpet'
gem 'rinku'
gem 'sanitize'

# Rack
gem 'crawler_detect'
gem 'rack-attack'
gem 'rack-cors'
gem 'rack-utf8_sanitizer', '1.10.1'

#  Everything else
gem 'chroma' # for manipulating colours
gem 'digest' # for generating hashes
gem 'haikunator' # for generating random names
gem 'mini_magick' # for image processing
```

## Frontend dependencies

```
<link rel="preconnect" href="https://cdnjs.cloudflare.com">
<link rel="preconnect" href="https://rawcdn.githack.com">
<link rel="preconnect" href="https://js.stripe.com">
<link rel="preconnect" href="https://maps.googleapis.com">
<link rel="preconnect" href="https://cdn.iframe.ly">
<link rel="preconnect" href="https://challenges.cloudflare.com">

<link href="/infinite_admin/plugins/icon/themify-icons/themify-icons.css" rel="stylesheet">
<link href="/infinite_admin/plugins/bootstrap/bootstrap4/css/bootstrap.css" rel="stylesheet">
<link href="/infinite_admin/plugins/animate/animate.min.css" rel="stylesheet">

<script src="https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js"></script>

<% FRONTEND_DEPENDENCIES.each do |base_url, libs| %>
  <% libs.each do |path, files| %>
    <% files.split(' ').each do |f| %>
      <% url = path.nil? ? "#{base_url}#{f}" : "#{base_url}#{path}/#{f}" %>
      <% ext = f.split('.').last.to_sym %>
      <% url += "?#{@cachebuster}" if base_url == '/javascripts/' %>
      <% case ext %>
      <% when :js %>
        <script src="<%= url %>" defer></script>
      <% when :css %>
        <link rel="stylesheet" href="<%= url %>">
      <% end %>
    <% end %>
  <% end %>
<% end %>

<link rel="stylesheet" href="/stylesheets/app.css?<%= @cachebuster %>">

<% [
     '//challenges.cloudflare.com/turnstile/v0/api.js?compat=recaptcha',
     '//js.stripe.com/v3/',
     "//cdn.iframe.ly/embed.js?key=#{ENV['IFRAMELY_KEY']}",
     "//maps.googleapis.com/maps/api/js?key=#{ENV['GOOGLE_MAPS_PUBLIC_API_KEY']}&libraries=places"
   ].each do |f| %>
  <script src="<%= f %>" defer></script>
<% end %>

<% unless ENV['CREATE_VIDEO'] %>
  <script>
    window.paceOptions = { ajax: { trackWebSockets: false } };
  </script>
  <script src="/infinite_admin/plugins/loader/pace/pace.min.js" defer></script>
<% end %>
<script src="/infinite_admin/plugins/cookie/js/js.cookie.js" defer></script>
<script src="/infinite_admin/plugins/tooltip/popper/popper.min.js" defer></script>
<script src="/infinite_admin/plugins/bootstrap/bootstrap4/js/bootstrap.js" defer></script>
<script src="/infinite_admin/plugins/scrollbar/slimscroll/jquery.slimscroll.min.js" defer></script>
<script src="/infinite_admin/js/apps.js?<%= @cachebuster %>" defer></script>

<script>
  $(function () { App.init(); });
</script>
```
