namespace :bootstrap do
  desc 'Compile app/assets/stylesheets/bootstrap.scss to bootstrap.css (needs Node)'
  task :build do
    require 'tmpdir'

    stylesheets_dir = File.expand_path('../app/assets/stylesheets', __dir__)
    abort 'rake bootstrap:build needs Node (npm)' unless system('npm --version', out: File::NULL)

    Dir.mktmpdir do |dir|
      puts 'Installing Bootstrap 4.6.2 and Dart Sass...'
      system('npm', 'install', '--prefix', dir, '--no-save', '--silent', 'bootstrap@4.6.2', 'sass@1.105.0', exception: true)

      puts 'Compiling bootstrap.scss...'
      css_file = File.join(dir, 'bootstrap.css')
      system(File.join(dir, 'node_modules', '.bin', 'sass'), '--no-source-map', '--quiet-deps', '--silence-deprecation=import',
             "--load-path=#{File.join(dir, 'node_modules')}", File.join(stylesheets_dir, 'bootstrap.scss'), css_file, exception: true)
      css = File.read(css_file, encoding: 'UTF-8')

      # Keep the output ASCII (no @charset) with colours as hex and integer rgba, as Ruby Sass wrote them
      channels = ->(match) { match.captures.first(3).map { |c| (c.end_with?('%') ? c.to_f * 2.55 : c.to_f).round.clamp(0, 255) } }
      css = css.sub(/\A@charset "UTF-8";\n/, '')
      css = css.gsub(%("\u2014\u00A0")) { '"\2014\00A0"' }
      css = css.gsub(/rgb\(([\d.]+%?), ([\d.]+%?), ([\d.]+%?)\)/) { "##{channels.call(Regexp.last_match).map { |c| format('%02x', c) }.join}" }
      css = css.gsub(/rgba\(([\d.]+%?), ([\d.]+%?), ([\d.]+%?), ([\d.]+)\)/) do
        "rgba(#{channels.call(Regexp.last_match).join(', ')}, #{Regexp.last_match(4)})"
      end
      abort "bootstrap.css has non-ASCII characters: #{css.chars.reject(&:ascii_only?).uniq.join}" unless css.ascii_only?

      header = <<~CSS
        /*
         * Compiled from bootstrap.scss by `rake bootstrap:build`. Don't edit this file:
         * change Bootstrap variables in bootstrap.scss, and override Bootstrap in app.css.
         */
      CSS
      File.write(File.join(stylesheets_dir, 'bootstrap.css'), header + css)
      puts 'Wrote app/assets/stylesheets/bootstrap.css'
    end
  end
end
