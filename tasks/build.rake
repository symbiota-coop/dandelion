# Tasks that build the vendored files in app/assets (AGENTS.md, Build/vendored code). Each needs Node, and a built file
# changes only with its source, which script/lint checks

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

namespace :ckeditor do
  desc 'Build the CKEditor 5 editor in ckeditor/ to app/assets/javascripts/ext/ckeditor.js (needs Node)'
  task :build do
    require 'tmpdir'

    source_dir = File.expand_path('../ckeditor', __dir__)
    javascripts_dir = File.expand_path('../app/assets/javascripts/ext', __dir__)
    abort 'rake ckeditor:build needs Node (npm)' unless system('npm --version', out: File::NULL)

    Dir.mktmpdir do |dir|
      FileUtils.cp_r(%w[package.json yarn.lock webpack.config.js src].map { |f| File.join(source_dir, f) }, dir)

      # yarn.lock pins the exact version of every package, so the build comes out the same each time
      puts 'Installing CKEditor 5 packages...'
      system('npx', '--yes', 'yarn@1.22.22', 'install', '--frozen-lockfile', '--silent', '--ignore-scripts', chdir: dir, exception: true)

      puts 'Building ckeditor.js...'
      system('npx', '--yes', 'yarn@1.22.22', '--silent', 'build', chdir: dir, out: File::NULL, exception: true)

      FileUtils.cp(File.join(dir, 'build', 'ckeditor.js'), File.join(javascripts_dir, 'ckeditor.js'))
      puts 'Wrote app/assets/javascripts/ext/ckeditor.js'
    end
  end
end

namespace :jquery_ui do
  desc 'Build the jQuery UI modules we use into app/assets/javascripts/ext (needs Node)'
  task :build do
    # The jQuery UI modules we use, in dependency order. Every page loads the autocomplete (header search, messages search,
    # location fields); the pages that drag things load the interactions too, which build on its widget factory
    builds = {
      'jquery-ui-autocomplete.min.js' => %w[version keycode position unique-id widget widgets/menu widgets/autocomplete],
      'jquery-ui-interactions.min.js' => %w[data scroll-parent plugin widgets/mouse widgets/sortable widgets/draggable widgets/droppable]
    }.freeze

    require 'date'
    require 'tmpdir'

    javascripts_dir = File.expand_path('../app/assets/javascripts/ext', __dir__)
    abort 'rake jquery_ui:build needs Node (npm)' unless system('npm --version', out: File::NULL)

    Dir.mktmpdir do |dir|
      # --before keeps to package versions published at least 7 days ago, like the Gemfile's cooldown
      puts 'Installing jQuery UI 1.14.2 and Terser...'
      system('npm', 'install', '--prefix', dir, '--no-save', '--silent', "--before=#{(Date.today - 7).iso8601}", 'jquery-ui@1.14.2', 'terser@5.51.2', exception: true)

      builds.each do |file, modules|
        sources = modules.map { |m| File.join(dir, 'node_modules', 'jquery-ui', 'ui', "#{m}.js") }
        output = File.join(dir, file)
        # Each module's licence banner is replaced by the one in the header
        system(File.join(dir, 'node_modules', '.bin', 'terser'), *sources, '--compress', '--mangle', '--comments', 'false', '--output', output, exception: true)

        header = <<~JS
          /*! jQuery UI 1.14.2 (#{modules.join(', ')}) | (c) OpenJS Foundation and other contributors | jqueryui.com/about | MIT license */
          // Built by `rake jquery_ui:build`. Don't edit this file: change the modules in tasks/build.rake and run it again
        JS
        File.write(File.join(javascripts_dir, file), header + File.read(output, encoding: 'UTF-8') + "\n")
        puts "Wrote app/assets/javascripts/ext/#{file}"
      end
    end
  end
end
