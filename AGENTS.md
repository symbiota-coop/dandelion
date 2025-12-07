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
<link rel="preconnect" href="https://cdn.jsdelivr.net">
<link rel="preconnect" href="https://js.stripe.com">
<link rel="preconnect" href="https://maps.googleapis.com">
<link rel="preconnect" href="https://cdn.iframe.ly">
<link rel="preconnect" href="https://challenges.cloudflare.com">

<link href="/infinite_admin/plugins/icon/themify-icons/themify-icons.css" rel="stylesheet">
<link href="/infinite_admin/plugins/bootstrap/bootstrap4/css/bootstrap.css" rel="stylesheet">
<link href="/infinite_admin/plugins/animate/animate.min.css" rel="stylesheet">

<script src="https://cdnjs.cloudflare.com/ajax/libs/jquery/3.7.1/jquery.min.js"></script>

<% {
      'jqueryui/1.13.2' => 'jquery-ui.min.js themes/base/jquery-ui.min.css',
      'jquery-timeago/1.4.3' => 'jquery.timeago.min.js',
      'moment.js/2.17.1' => 'moment.min.js locale/en-gb.js',
      'moment-timezone/0.5.43' => 'moment-timezone.min.js moment-timezone-with-data.min.js',
      'flatpickr/4.6.13' => 'flatpickr.min.js flatpickr.min.css',
      'datatables/1.10.16' => 'js/jquery.dataTables.min.js js/dataTables.bootstrap4.min.js css/dataTables.bootstrap4.min.css',       
      'tributejs/3.5.3' => 'tribute.min.js tribute.min.css',
      'select2/3.5.2' => 'select2.min.js select2.min.css',
      'sticky-table-headers/0.1.24' => 'js/jquery.stickytableheaders.min.js',
      'iframe-resizer/4.2.10' => 'iframeResizer.contentWindow.min.js',
      'slick-carousel/1.8.1' => 'slick.min.js slick.min.css slick-theme.min.css',
      'Chart.js/3.5.1' => 'chart.js',
      'web3/1.3.4' => 'web3.min.js',
      'intro.js/6.0.0' => 'intro.min.js introjs.min.css',
      'qrcodejs/1.0.0' => 'qrcode.min.js',
      'masonry/4.0.0' => 'masonry.pkgd.min.js',
      'TypeWatch/3.0.2' => 'jquery.typewatch.min.js',
      'bootstrap-icons/1.11.3' => 'font/bootstrap-icons.min.css',
      'typed.js/2.0.10' => 'typed.min.js',
      'fullcalendar/6.1.19' => 'index.global.min.js'    
     }.each { |k,v| %>
<% v.split(' ').each { |f| u = "https://cdnjs.cloudflare.com/ajax/libs/#{k}/#{f}" %>
<% case f.split('.').last.to_sym; when :js %>
  <script src="<%= u %>" defer></script>
<% when :css %>
  <link rel="stylesheet" href="<%= u %>">
<% end %>
<% } %>
<% } %>

<% [
     '//rawcdn.githack.com/scottdejonge/map-icons/dbf6fd7caedd60d11b5bfb5f267a114a6847d012/dist/css/map-icons.min.css',
     '//cdn.jsdelivr.net/gh/mdbassit/Coloris@latest/dist/coloris.min.css',
     "/stylesheets/app.css?#{@cachebuster}"
   ].each { |f| %>
<link rel="stylesheet" href="<%= f %>">
<% } %>

<% [
     '//challenges.cloudflare.com/turnstile/v0/api.js?compat=recaptcha',
     '//js.stripe.com/v3/',
     "//cdn.iframe.ly/embed.js?key=#{ENV['IFRAMELY_KEY']}",
     "//maps.googleapis.com/maps/api/js?key=#{ENV['GOOGLE_MAPS_PUBLIC_API_KEY']}&libraries=places",
     '//rawcdn.githack.com/bassjobsen/Bootstrap-3-Typeahead/067bd296184a4dda8c669923417124065b4ebced/bootstrap3-typeahead.min.js',
     '//rawcdn.githack.com/mahnunchik/markerclustererplus/736b0e3a7d916fbeb2ee5007494f17a5329b11a8/src/markerclusterer.js',
     '//rawcdn.githack.com/scottdejonge/map-icons/dbf6fd7caedd60d11b5bfb5f267a114a6847d012/dist/js/map-icons.js',
     '//rawcdn.githack.com/scottgonzalez/jquery-ui-extensions/fb7fd7df3d70e0288394f07bfe78262b548c30d6/src/autocomplete/jquery.ui.autocomplete.html.js',
     '//cdn.jsdelivr.net/npm/chartjs-plugin-datalabels@2.0.0',
     '//cdn.jsdelivr.net/gh/mdbassit/Coloris@latest/dist/coloris.min.js',
     "/javascripts/ext/ckeditor.js?#{@cachebuster}",     
     '/javascripts/ext/autosize.js',     
     '/javascripts/ext/countUp.umd.js',     
     '/javascripts/ext/jquery-deparam.js',     
     '/javascripts/ext/linkify.min.js',     
     '/javascripts/ext/linkify-jquery.min.js',     
     "/javascripts/pagelets.js?#{@cachebuster}",
     "/javascripts/jquery.lookup.js?#{@cachebuster}",
     "/javascripts/map.js?#{@cachebuster}",
     "/javascripts/currencySymbol.js?#{@cachebuster}",
     "/javascripts/serializeObject.js?#{@cachebuster}",
     "/javascripts/app.js?#{@cachebuster}"
   ].each { |f| %>
<script src="<%= f %>" defer></script>
<% } %>

<% unless ENV['CREATE_VIDEO'] %>
  <script>
    window.paceOptions = {
        ajax: {
            trackWebSockets: false
        }
    };
  </script>
  <script src="/infinite_admin/plugins/loader/pace/pace.min.js" defer></script>
<% end %>
<script src="/infinite_admin/plugins/cookie/js/js.cookie.js" defer></script>
<script src="/infinite_admin/plugins/tooltip/popper/popper.min.js" defer></script>
<script src="/infinite_admin/plugins/bootstrap/bootstrap4/js/bootstrap.js" defer></script>
<script src="/infinite_admin/plugins/scrollbar/slimscroll/jquery.slimscroll.min.js" defer></script>
<script src="/infinite_admin/js/apps.js?<%= @cachebuster %>" defer></script>

<script>
  $(function () {
    App.init();
  });
</script>
```
