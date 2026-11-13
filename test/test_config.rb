$VERBOSE = nil
require_relative 'test_coverage'
require File.expand_path('../config/boot', __dir__)
raise "Refusing to run tests outside test environment. Current Padrino.env=#{Padrino.env.inspect}. Run with `env -u BUNDLE_PATH foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb`" unless Padrino.env == :test

require 'capybara'
require 'capybara/dsl'
require 'capybara/cuprite'
require 'factory_bot'
require 'minitest/autorun'
require 'minitest/mock'
require 'minitest/rg'
require 'rack/test'
require_relative 'helpers/test_helpers'

# No test reaches Mailgun: Mailer sends through an organisation's own account whenever it has an API key, even here, so
# an email a test doesn't record (recorded_email, recorded_emails) would otherwise really be sent
module RefuseMailgunInTests
  %i[get post put delete].each do |verb|
    define_method(verb) { |*| raise "A test tried to reach Mailgun (#{verb.upcase}): record the email with recorded_email(s)" }
  end
end
Mailgun::Client.prepend(RefuseMailgunInTests)

# Tests fake ImageMagick, so they don't need it installed and stay fast: Dragonfly only runs identify (format and size)
# and convert, which the fake answers from the file's header and by copying it, and refuses a file that isn't an image
# as ImageMagick's policy would. MiniMagick is refused: stub it. Only a test of ImageMagick itself runs the real one,
# inside with_imagemagick (TestHelpers), in the CI group that installs it (with images)
module FakeImageMagick
  class << self
    attr_accessor :real
  end

  def self.identify(path)
    format, width, height = header(File.binread(path, 65_536))
    raise Dragonfly::Shell::CommandFailed, "identify: no decode delegate for #{path}" unless format

    "#{format} #{width} #{height}"
  end

  def self.header(data)
    data = data.b
    if data.start_with?("\x89PNG".b) then ['PNG', *data[16, 8].unpack('NN')]
    elsif data.start_with?('GIF8') then ['GIF', *data[6, 4].unpack('vv')]
    elsif data.start_with?("\xFF\xD8".b) then ['JPEG', *jpeg_size(data)]
    elsif data[0, 4] == 'RIFF' && data[8, 4] == 'WEBP' then ['WEBP', 100, 100]
    elsif data[4, 8].to_s.match?(/\Aftyp(heic|heix|mif1)/) then ['HEIC', 100, 100]
    end
  end

  # Copies the input to the output, or writes a JPEG of its size when asked for one (-format jpeg, or a .jpg output)
  def self.convert(args)
    input = args[1...-1].map { |arg| arg.sub(/\A\w+:/, '').sub(/\[\d+\]\z/, '') }.find { |arg| File.file?(arg) }
    format, width, height = header(File.binread(input, 65_536))
    raise Dragonfly::Shell::CommandFailed, "convert: no decode delegate for #{input}" unless format

    target = args.include?('-format') ? args[args.index('-format') + 1] : File.extname(args.last).delete('.')
    if %w[jpeg jpg].include?(target.to_s.downcase) && format != 'JPEG'
      File.binwrite(args.last, jpeg(width, height))
    else
      FileUtils.cp(input, args.last)
    end
    ''
  end

  # The start and frame header of a JPEG, all identify reads
  def self.jpeg(width, height)
    "\xFF\xD8\xFF\xC0".b + [17, 8, height, width, 3].pack('nCnnC') + "\x01\x22\x00\x02\x11\x01\x03\x11\x01\xFF\xD9".b
  end

  # From the frame header (SOFn), after the segments before it
  def self.jpeg_size(data)
    index = 2
    while index + 9 < data.bytesize
      marker = data.getbyte(index + 1)
      return [data[index + 7, 2].unpack1('n'), data[index + 5, 2].unpack1('n')] if (0xC0..0xCF).cover?(marker) && ![0xC4, 0xC8, 0xCC].include?(marker)

      index += 2 + data[index + 2, 2].unpack1('n')
    end
    [1, 1]
  end

  # Dragonfly::Shell
  module Shell
    def run(command, opts = {})
      return super if FakeImageMagick.real

      args = command.shellsplit
      args.shift if File.basename(args.first) == 'magick'
      case File.basename(args.first)
      when 'identify' then FakeImageMagick.identify(args.last)
      when 'convert' then FakeImageMagick.convert(args)
      else raise "The fake ImageMagick doesn't run #{args.first}: check ImageMagick itself inside with_imagemagick"
      end
    end
  end

  # MiniMagick::Shell
  module RefuseMiniMagick
    def run(*, **)
      return super if FakeImageMagick.real

      raise 'A test ran MiniMagick: stub it, or check ImageMagick itself inside with_imagemagick'
    end
  end
end
Dragonfly::Shell.prepend(FakeImageMagick::Shell)
MiniMagick::Shell.prepend(FakeImageMagick::RefuseMiniMagick)

Capybara.app = Padrino.application
Capybara.server_port = ENV['PORT']
# Each run saves its screenshots to its own folder, so runs at the same time don't delete each other's
Capybara.save_path = ENV['CREATE_VIDEO'] ? 'capybara' : "capybara/#{Process.pid}"
Capybara.default_max_wait_time = 10

Capybara.register_driver :cuprite do |app|
  options = {}
  options[:js_errors] = true # a JavaScript error on the page fails the test
  # Tests have no Maps key, so the Maps API is blocked: otherwise Google's own scripts, which change weekly, can throw
  # on the page and fail tests that aren't about maps. Maps show their could-not-load message, and tests of places.js
  # fake the Places library (FAKE_PLACES_JS in accounts/accounts_test.rb)
  options[:url_blacklist] = [%r{\Ahttps://maps\.googleapis\.com/}]
  options[:timeout] = 60
  options[:process_timeout] = 30
  options[:window_size] = ENV['CREATE_VIDEO'] ? [1920, 1080] : [1280, 720]
  options[:headless] = true
  options[:browser_options] = {}
  # Reduced motion turns off the view transitions between pages (app.css), which Chrome aborts with a page error when a
  # click navigates again before the last one has finished, and the app's other transitions, so nothing waits on them
  options[:browser_options]['force-prefers-reduced-motion'] = nil
  options[:browser_options]['no-sandbox'] = nil if Process.uid.zero? # Chromium won't start as root (e.g. cloud agent containers) otherwise
  options[:browser_options]['proxy-server'] = ENV['HTTPS_PROXY'] if ENV['HTTPS_PROXY'] # Chromium ignores HTTPS_PROXY, so CDN requests fail behind an agent proxy
  Capybara::Cuprite::Driver.new(app, options)
end
Capybara.javascript_driver = :cuprite
Capybara.default_driver = :cuprite

# Tests don't look email domains up in DNS: it's slow, and a domain that stops resolving fails tests that aren't about it
EmailAddress::Config.configure(host_validation: :syntax)

# Configure Geocoder for testing (avoid real API calls)
Geocoder.configure(lookup: :test)
Geocoder::Lookup::Test.set_default_stub([{ 'coordinates' => [59.3251, 18.0685] }]) # Gamla Stan coords (111 28, Sweden)

test_run_running = lambda do |pid|
  Process.kill(0, pid)
  true
rescue Errno::ESRCH
  false
rescue Errno::EPERM
  true
end

# Drop this run's database (see config/boot.rb) when it ends, and any left by runs that didn't finish
Mongoid.default_client.database_names.grep(/\Adandelion_test_(\d+)\z/) do |name|
  Mongoid.default_client.use(name).database.drop unless test_run_running.call(Regexp.last_match(1).to_i)
end
Minitest.after_run { Mongoid.default_client.database.drop }

# Remove the screenshots of runs that have finished, once they're an hour old
Dir.glob('capybara/*/').each do |dir|
  pid = File.basename(dir)
  FileUtils.rm_rf(dir) if pid.match?(/\A\d+\z/) && !test_run_running.call(pid.to_i) && File.mtime(dir) < 1.hour.ago
rescue Errno::ENOENT
  # Another run starting at the same time removed it first
end

# RECORD_ROUTES=1 records which routes each test requests, in tmp/routes/<pid>.json, for finding the tests that cover
# a route (covers_route). CI's Run workflow does it with record routes ticked, as the routes artifact
module RouteRecording
  REQUESTS = Hash.new { |hash, test| hash[test] = Set.new }

  class << self
    attr_accessor :test
  end
end

if ENV['RECORD_ROUTES'].present? # CI sets it empty unless asked for
  # As the route is matched, before the app's own before filters can halt it
  Dandelion::App.before do
    route = request.route_obj
    # Padrino adds (.:format)? to the path the controller wrote, and keeps / as ''. HEAD is the GET route's
    path = route.original_path.delete_suffix('(.:format)?') if route
    path = '/' if path == ''
    RouteRecording::REQUESTS[RouteRecording.test] << "#{route.verb.sub('HEAD', 'GET')} #{path}" if route && RouteRecording.test
  end
  Minitest.after_run do
    FileUtils.mkdir_p('tmp/routes')
    File.write("tmp/routes/#{Process.pid}.json", RouteRecording::REQUESTS.transform_values(&:to_a).to_json)
  end
end

module ActiveSupport
  class TestCase
    include TestHelpers

    # In CI a failing test runs again, up to TEST_ATTEMPTS times in all, before it counts as failed: browser tests can
    # fail on timing alone. Each attempt is a fresh instance, and setup's reset! empties the database first. A test that
    # passes on a later attempt gets a warning on the run's summary, so flaky tests stay visible. Locally a test runs
    # once, so a real failure shows at once rather than after three runs
    TEST_ATTEMPTS = ENV['CI'] ? 3 : 1

    # Minitest's own hook for how one test runs (Minitest::Runnable.run)
    def self.run(klass, method_name, reporter)
      reporter.prerecord klass, method_name
      result = nil
      (1..TEST_ATTEMPTS).each do |attempt|
        result = klass.new(method_name).run
        if result.passed? || result.skipped?
          puts "::warning title=Flaky test::#{klass}##{method_name} passed on attempt #{attempt} of #{TEST_ATTEMPTS}" if attempt > 1
          break
        end
        puts "\n🔁 #{klass}##{method_name} failed on attempt #{attempt} of #{TEST_ATTEMPTS}: #{result.failure.message.lines.first}" if attempt < TEST_ATTEMPTS
      end
      reporter.record result
    end

    setup do
      puts "\n🧪 Running: #{name}"
      RouteRecording.test = "#{self.class.instance_method(name).source_location.join(':')} #{name}" if ENV['RECORD_ROUTES'].present?
      reset!
      if ENV['CREATE_VIDEO']
        FileUtils.rm_f(Dir.glob("#{Capybara.save_path}/*.{png,mp4}"))
        @video_steps = []
        @client = OpenAI::Client.new(access_token: ENV['OPENAI_API_KEY'])
      end
    end

    teardown do
      # Only once the test has used the page (Capybara's own flag, with no reader): a screenshot starts Chrome, which
      # model and Rack tests otherwise never need, and which can't start in some agents' sandboxes (Codex's on macOS)
      save_screenshot if !ENV['CI'] && respond_to?(:save_screenshot) && page.instance_variable_get(:@touched)
    end

    # The doc claims this test checks, as 'page/id@hash' (lib/doc_claims.rb): test/lint_test.rb reads them, so they do
    # nothing here
    def covers(*claims); end

    # The routes this test is about, as 'VERB /path' as the controller writes it (lib/route_marks.rb): test/lint_test.rb
    # reads them, so they do nothing here
    def covers_route(*routes); end

    def reset!
      Capybara.reset_sessions!
      AppModels.all.each do |model|
        next unless model.respond_to?(:delete_all)

        # Paranoia models scope delete_all to non-deleted rows; purge soft-deleted rows too
        (model.respond_to?(:unscoped) ? model.unscoped : model).delete_all
      end
      Delayed::Job.delete_all # not an app model, so a test's queued jobs would count in the next
    end

    # Rack::Test's app
    def app
      Padrino.application
    end
  end
end
