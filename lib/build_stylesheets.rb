stylesheets_dir = Padrino.root('app', 'assets', 'stylesheets')
Dir.glob(File.join(stylesheets_dir, '*.scss')).each do |scss_file|
  css_file = scss_file.gsub('.scss', '.css')
  begin
    scss_content = File.read(scss_file)
    css_content = Sass::Engine.new(scss_content,
                                   syntax: :scss,
                                   load_paths: [stylesheets_dir] # ← This tells Sass where to find imports
                                  ).render
    File.write(css_file, css_content)
  rescue StandardError => e
    puts "Warning: Failed to compile #{File.basename(scss_file)}: #{e.message}"
  end
end
