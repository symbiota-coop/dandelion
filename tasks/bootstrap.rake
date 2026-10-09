namespace :bootstrap do
  desc 'Compile app/assets/stylesheets/bootstrap5.scss to bootstrap5.css and copy in bootstrap.bundle.min.js (needs Node)'
  task :build do
    require 'date'
    require 'tmpdir'

    stylesheets_dir = File.expand_path('../app/assets/stylesheets', __dir__)
    javascripts_dir = File.expand_path('../app/assets/javascripts/ext', __dir__)
    abort 'rake bootstrap:build needs Node (npm)' unless system('npm --version', out: File::NULL)

    Dir.mktmpdir do |dir|
      # --before keeps to package versions published at least 7 days ago, like the Gemfile's cooldown
      puts 'Installing Bootstrap 5.3.8 and Dart Sass...'
      system('npm', 'install', '--prefix', dir, '--no-save', '--silent', "--before=#{(Date.today - 7).iso8601}", 'bootstrap@5.3.8', 'sass@1.105.0', exception: true)

      puts 'Compiling bootstrap5.scss...'
      css_file = File.join(dir, 'bootstrap5.css')
      system(File.join(dir, 'node_modules', '.bin', 'sass'), '--no-source-map', '--quiet-deps', '--silence-deprecation=import',
             "--load-path=#{File.join(dir, 'node_modules')}", File.join(stylesheets_dir, 'bootstrap5.scss'), css_file, exception: true)
      css = File.read(css_file, encoding: 'UTF-8')

      # Keep the output ASCII (no @charset) with colours as hex and integer rgba, as Ruby Sass wrote them
      channels = ->(match) { match.captures.first(3).map { |c| (c.end_with?('%') ? c.to_f * 2.55 : c.to_f).round.clamp(0, 255) } }
      css = css.sub(/\A@charset "UTF-8";\n/, '')
      css = css.gsub(%("\u2014\u00A0")) { '"\2014\00A0"' }
      css = css.gsub(/rgb\(([\d.]+%?), ([\d.]+%?), ([\d.]+%?)\)/) { "##{channels.call(Regexp.last_match).map { |c| format('%02x', c) }.join}" }
      css = css.gsub(/rgba\(([\d.]+%?), ([\d.]+%?), ([\d.]+%?), ([\d.]+)\)/) do
        "rgba(#{channels.call(Regexp.last_match).join(', ')}, #{Regexp.last_match(4)})"
      end
      abort "bootstrap5.css has non-ASCII characters: #{css.chars.reject(&:ascii_only?).uniq.join}" unless css.ascii_only?

      header = <<~CSS
        /*
         * Compiled from bootstrap5.scss by `rake bootstrap:build`. Don't edit this file:
         * change Bootstrap variables in bootstrap5.scss, and override Bootstrap in app.css.
         */
      CSS
      File.write(File.join(stylesheets_dir, 'bootstrap5.css'), header + css)
      puts 'Wrote app/assets/stylesheets/bootstrap5.css'

      # The bundle includes Popper; drop the source map comment, as we don't serve the map
      js = File.read(File.join(dir, 'node_modules', 'bootstrap', 'dist', 'js', 'bootstrap.bundle.min.js'), encoding: 'UTF-8')
      File.write(File.join(javascripts_dir, 'bootstrap.bundle.min.js'), js.sub(%r{\n//# sourceMappingURL=.*\z}, "\n"))
      puts 'Wrote app/assets/javascripts/ext/bootstrap.bundle.min.js'
    end
  end
end
