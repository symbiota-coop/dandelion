module VideoNarrationHelper
  def narrate(narration, action = nil)
    label = "#{name}_#{@step}"

    if ENV['CREATE_VIDEO']
      hash = ::Digest::SHA256.hexdigest(narration)

      unless File.exist?("#{Capybara.save_path}/#{label}_#{hash}.aac")
        puts "generating #{label}_#{hash}.aac"
        response = @client.audio.speech(
          parameters: { model: 'tts-1', input: narration, voice: 'fable', response_format: 'aac' }
        )
        File.binwrite("#{Capybara.save_path}/#{label}_#{hash}.aac", response)
      end

      save_viewport_screenshot("#{label}_before_#{hash}.png")
    end

    unless action.nil?
      action.call
      save_viewport_screenshot("#{label}_after_#{hash}.png") if ENV['CREATE_VIDEO']
    end

    @step += 1 if ENV['CREATE_VIDEO']
  end

  def save_viewport_screenshot(path)
    evaluate_async_script <<~JS
      const done = arguments[0];
      requestAnimationFrame(() => {
        const animations = document.getAnimations().filter((animation) => {
          const endTime = animation.effect?.getComputedTiming().endTime;
          return Number.isFinite(endTime) && animation.playState !== 'finished';
        });
        Promise.allSettled(animations.map((animation) => animation.finished)).then(done);
      });
    JS

    x, y, width, height = evaluate_script(
      '[window.scrollX, window.scrollY, window.innerWidth, window.innerHeight]'
    )
    save_screenshot(path, area: { x: x, y: y, width: width, height: height }) # rubocop:disable Lint/Debugger
  end

  def create_video
    return unless ENV['CREATE_VIDEO']

    image_files = Dir.glob("#{Capybara.save_path}/*_before_*.png").sort_by { |file| file[/\d+/].to_i }

    silent_input = '-f lavfi -t 2 -i anullsrc=r=44100:cl=stereo'
    video_options = '-c:v libx264 -preset veryfast -pix_fmt yuv420p'
    audio_options = '-ar 44100 -ac 2 -c:a aac -b:a 192k'

    # Open file list for concatenation
    File.open("#{Capybara.save_path}/file_list.txt", 'w') do |file|
      image_files.each do |image|
        before_image = image
        after_image = image.sub('_before', '_after')
        audio = image.sub('_before', '').sub('.png', '.aac')
        label = image.split('/').last.split('_before_').first

        puts "label: #{label}"
        puts "before_image: #{before_image}"
        puts "after_image: #{after_image}"
        puts "audio: #{audio}"

        # Generate individual video for each image/audio pair
        system("ffmpeg -loop 1 -i #{before_image} #{silent_input} #{video_options} #{audio_options} -shortest #{Capybara.save_path}/#{label}_before.mp4") if File.exist?(after_image)
        system("ffmpeg -loop 1 -i #{before_image} -i #{audio} #{video_options} #{audio_options} -shortest #{Capybara.save_path}/#{label}_during.mp4")
        system("ffmpeg -loop 1 -i #{after_image} #{silent_input} #{video_options} #{audio_options} -shortest #{Capybara.save_path}/#{label}_after.mp4") if File.exist?(after_image)

        # Add entries to file list for concatenation
        file.puts("file '#{label}_before.mp4'") if File.exist?(after_image)
        file.puts("file '#{label}_during.mp4'")
        file.puts("file '#{label}_after.mp4'") if File.exist?(after_image)
      end

      # Add 2 extra seconds of silence at the end using the last image
      last_image = image_files.last
      system("ffmpeg -loop 1 -i #{last_image} #{silent_input} #{video_options} #{audio_options} -shortest #{Capybara.save_path}/finale.mp4")
      file.puts("file 'finale.mp4'")
    end

    # Concatenate all the individual video segments into a final video
    system("ffmpeg -f concat -safe 0 -i #{Capybara.save_path}/file_list.txt -c copy #{Capybara.save_path}/#{name.sub('test_', '')}.mp4")
  end
end
