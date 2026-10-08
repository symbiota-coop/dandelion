module VideoNarrationHelper
  PAUSE = 2 # seconds of silence around each action

  def narrate(narration, action = nil)
    unless ENV['CREATE_VIDEO']
      action&.call
      return
    end

    narration = narration.squish
    label = "#{name}_#{@video_steps.size + 1}"
    audio = "#{Capybara.save_path}/#{label}_#{::Digest::SHA256.hexdigest(narration)}.mp3"
    # Generate the narration in the background while the test carries on; create_video waits for it
    duration = Thread.new do
      unless File.size?(audio)
        puts "generating #{audio}"
        File.binwrite(audio, @client.audio.speech(parameters: { model: 'tts-1', input: narration, voice: 'fable', response_format: 'mp3' }))
      end
      audio_duration(audio)
    end

    step = { audio: audio, duration: duration, before: save_viewport_screenshot("#{label}_before.png") }
    if action
      action.call
      step[:after] = save_viewport_screenshot("#{label}_after.png")
    end
    @video_steps << step
  end

  def save_viewport_screenshot(filename)
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
    save_screenshot(filename, area: { x: x, y: y, width: width, height: height }) # rubocop:disable Lint/Debugger
    "#{Capybara.save_path}/#{filename}"
  end

  # Builds the video in a single ffmpeg pass: the screenshots as a slideshow, over the narration with silence between.
  # For each step: the before screenshot (silent, if the step has an action), the before screenshot with the narration,
  # then the after screenshot (silent); and finally the last screenshot (silent).
  def create_video
    return unless ENV['CREATE_VIDEO']

    segments = [] # [image, seconds, audio or nil]
    @video_steps.each do |step|
      segments << [step[:before], PAUSE, nil] if step[:after]
      segments << [step[:before], step[:duration].value, step[:audio]]
      segments << [step[:after], PAUSE, nil] if step[:after]
    end
    segments << [segments.last[0], PAUSE, nil]

    # The concat demuxer ignores the last entry's duration, so the last image is listed again
    slideshow = "#{Capybara.save_path}/slideshow.txt"
    File.write(slideshow, segments.map { |image, seconds, _| "file '#{File.basename(image)}'\nduration #{seconds}\n" }.join + "file '#{File.basename(segments.last[0])}'\n")

    audios = segments.filter_map { |_, _, audio| audio }
    input = 0
    filters = segments.each_with_index.map do |(_, seconds, audio), i|
      source = audio ? "[#{input += 1}:a]aformat=sample_rates=44100:channel_layouts=stereo,apad" : 'anullsrc=r=44100:cl=stereo'
      "#{source},atrim=duration=#{seconds}[a#{i}]"
    end
    filters << "#{segments.each_index.map { |i| "[a#{i}]" }.join}concat=n=#{segments.size}:v=0:a=1[a]"

    # Served from /videos (app/assets/videos), with the first screenshot as the poster
    output = Padrino.root('app', 'assets', 'videos', name.sub('test_', ''))
    FileUtils.mkdir_p(File.dirname(output))
    pids = [
      spawn(
        'ffmpeg', '-y', '-loglevel', 'error',
        '-f', 'concat', '-safe', '0', '-i', slideshow,
        *audios.flat_map { |audio| ['-i', audio] },
        '-filter_complex', filters.join(';'), '-map', '0:v', '-map', '[a]',
        '-r', '30', '-c:v', 'libx264', '-preset', 'veryfast', '-tune', 'stillimage', '-pix_fmt', 'yuv420p',
        '-c:a', 'aac', '-b:a', '192k', '-shortest', '-movflags', '+faststart',
        "#{output}.mp4"
      ),
      spawn('ffmpeg', '-y', '-loglevel', 'error', '-i', segments.first[0], '-q:v', '3', "#{output}.jpg")
    ]
    pids.each do |pid|
      _, status = Process.wait2(pid)
      raise 'ffmpeg failed' unless status.success?
    end
  end

  def audio_duration(audio)
    IO.popen(['ffprobe', '-v', 'error', '-show_entries', 'format=duration', '-of', 'csv=p=0', audio], &:read).to_f
  end
end
