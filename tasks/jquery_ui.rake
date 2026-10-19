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
          // Built by `rake jquery_ui:build`. Don't edit this file: change the modules in tasks/jquery_ui.rake and run it again
        JS
        File.write(File.join(javascripts_dir, file), header + File.read(output, encoding: 'UTF-8') + "\n")
        puts "Wrote app/assets/javascripts/ext/#{file}"
      end
    end
  end
end
