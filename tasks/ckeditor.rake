namespace :ckeditor do
  desc 'Build the CKEditor 5 editor in ckeditor/ to app/assets/javascripts/ext/ckeditor.js (needs Node)'
  task :build do
    require 'tmpdir'

    source_dir = File.expand_path('../ckeditor', __dir__)
    javascripts_dir = File.expand_path('../app/assets/javascripts/ext', __dir__)
    abort 'rake ckeditor:build needs Node (npm)' unless system('npm --version', out: File::NULL)

    Dir.mktmpdir do |dir|
      FileUtils.cp_r(%w[package.json yarn.lock webpack.config.js src].map { |f| File.join(source_dir, f) }, dir)

      # yarn.lock pins the CKEditor 27 packages, so the build comes out the same each time
      puts 'Installing CKEditor 5 packages...'
      system('npx', '--yes', 'yarn@1.22.22', 'install', '--frozen-lockfile', '--silent', '--ignore-scripts', chdir: dir, exception: true)

      puts 'Building ckeditor.js...'
      system('npx', '--yes', 'yarn@1.22.22', '--silent', 'build', chdir: dir, out: File::NULL, exception: true)

      # Drop the source map comment, as we don't serve the map
      js = File.read(File.join(dir, 'build', 'ckeditor.js'), encoding: 'UTF-8')
      File.write(File.join(javascripts_dir, 'ckeditor.js'), js.sub(%r{\n//# sourceMappingURL=.*\z}, "\n"))
      puts 'Wrote app/assets/javascripts/ext/ckeditor.js'
    end
  end
end
