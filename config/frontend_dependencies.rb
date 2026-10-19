require 'json'

# The version of each npm package the app loads from jsDelivr, from frontend/package.json
FRONTEND_VERSIONS = JSON.parse(File.read(File.expand_path('../frontend/package.json', __dir__)))['dependencies'].freeze

# A file of an npm package on jsDelivr, at the version frontend/package.json names
FRONTEND_NPM_URL = ->(package, file) { "https://cdn.jsdelivr.net/npm/#{package}@#{FRONTEND_VERSIONS.fetch(package)}/#{file}" }

# The hash of each CDN file the app loads, by its URL, from frontend/integrity.json (written by rake frontend:integrity).
# cdn_tag writes it as the file's integrity attribute, so the browser won't run a file that's changed
FRONTEND_INTEGRITY = JSON.parse(File.read(File.expand_path('../frontend/integrity.json', __dir__))).freeze

# The npm packages every page loads from jsDelivr, after jQuery, and their files
FRONTEND_DEPENDENCIES = {
  '@github/relative-time-element' => 'dist/bundle.js',
  'flatpickr' => 'dist/flatpickr.min.js dist/flatpickr.min.css',
  'datatables.net' => 'js/dataTables.min.js',
  'datatables.net-bs5' => 'js/dataTables.bootstrap5.min.js css/dataTables.bootstrap5.min.css',
  'select2' => 'dist/js/select2.full.min.js dist/css/select2.min.css',
  'select2-bootstrap-5-theme' => 'dist/select2-bootstrap-5-theme.min.css',
  'iframe-resizer' => 'js/iframeResizer.contentWindow.min.js',
  'slick-carousel' => 'slick/slick.min.js slick/slick.css slick/slick-theme.css',
  'chart.js' => 'dist/chart.umd.min.js',
  'intro.js' => 'minified/intro.min.js minified/introjs.min.css',
  'bootstrap-icons' => 'font/bootstrap-icons.min.css',
  'chartjs-plugin-datalabels' => 'dist/chartjs-plugin-datalabels.min.js',
  'autosize' => 'dist/autosize.min.js',
  '@googlemaps/markerclusterer' => 'dist/index.min.js',
  '@melloware/coloris' => 'dist/umd/coloris.min.js dist/coloris.min.css'
}.freeze

# Our own files every page loads
FRONTEND_LOCAL_FILES = {
  # jQuery UI's autocomplete, built from the modules we use (rake jquery_ui:build). Pages that drag things also load
  # jquery-ui-interactions.min.js
  'javascripts/ext' => 'ckeditor.js jquery-ui-autocomplete.min.js',
  'javascripts' => 'utils.js confirm.js pagelets.js map.js places.js cookie_consent.js sidebar.js header_search.js scrollspy.js app.js forms.js comments.js rich_text.js tabs.js wysiwyg.js sheets.js'
}.freeze

# Packages whose files are ES modules, loaded with type="module"
FRONTEND_MODULES = %w[@github/relative-time-element].freeze

# A cdn_tag call in a template: a package and its file (cdn_tag 'fullcalendar', 'all/global.js'), or the URL of a
# file that isn't an npm package's
FRONTEND_CDN_TAG = /cdn_tag[ (]+['"]([^'"]+)['"](?:,\s*['"]([^'"]+)['"])?/

# The URLs of the CDN files a template's cdn_tag calls load
FRONTEND_TEMPLATE_CDN_URLS = ->(source) { source.scan(FRONTEND_CDN_TAG).map { |name, file| file ? FRONTEND_NPM_URL.(name, file) : name } }

# Every CDN file the app loads: FRONTEND_DEPENDENCIES' and those templates load with cdn_tag. Each has a hash in
# FRONTEND_INTEGRITY
FRONTEND_CDN_URLS = lambda do |root|
  urls = FRONTEND_DEPENDENCIES.flat_map { |package, files| files.split.map { |f| FRONTEND_NPM_URL.(package, f) } }
  urls + Dir[File.join(root, 'app/views/**/*.erb')].flat_map { |f| FRONTEND_TEMPLATE_CDN_URLS.(File.read(f, encoding: 'UTF-8')) }
end
