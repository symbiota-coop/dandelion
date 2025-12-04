# rubocop:disable Lint/Debugger
$VERBOSE = nil
require File.expand_path('../config/boot', __dir__)

require 'capybara'
require 'capybara/dsl'
require 'capybara/cuprite'
require 'factory_bot'
require 'minitest/autorun'
require 'minitest/rg'

Capybara.app = Padrino.application
Capybara.server_port = ENV['PORT']
Capybara.save_path = 'capybara'
Capybara.default_max_wait_time = 10
FileUtils.rm_rf("#{Capybara.save_path}/.") unless ENV['CI'] || ENV['CREATE_VIDEO']

Capybara.register_driver :cuprite do |app|
  options = {}
  options[:js_errors] = false
  options[:timeout] = 60
  options[:process_timeout] = 30
  options[:window_size] = [1280, 720]
  Capybara::Cuprite::Driver.new(app, options)
end
Capybara.javascript_driver = :cuprite
Capybara.default_driver = :cuprite

module ActiveSupport
  class TestCase
    setup do
      puts "\n🧪 Running: #{name}"
      reset!
      if ENV['CREATE_VIDEO']
        FileUtils.rm_f(Dir.glob("#{Capybara.save_path}/*.{png,mp4}"))
        @step = 1
        @client = OpenAI::Client.new
      end
    end

    teardown do
      save_screenshot unless ENV['CI']
    end

    def reset!
      Capybara.reset_sessions!
      Dir.glob(Padrino.root('models', '*.rb')).each do |f|
        model = f.split('/').last.split('.').first.camelize.constantize
        model.delete_all if model.respond_to?(:delete_all)
      end
    end

    def login_as(account)
      account.generate_sign_in_token!
      visit "/?sign_in_token=#{account.sign_in_token}"
    end

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

        save_screenshot("#{label}_before_#{hash}.png")
      end

      unless action.nil?
        action.call
        save_screenshot("#{label}_after_#{hash}.png") if ENV['CREATE_VIDEO']
      end

      @step += 1 if ENV['CREATE_VIDEO']
    end

    def create_video
      return unless ENV['CREATE_VIDEO']

      image_files = Dir.glob("#{Capybara.save_path}/*_before_*.png").sort_by { |file| file[/\d+/].to_i }

      # Generate silent AAC audio file
      system("ffmpeg -f lavfi -i anullsrc=r=44100:cl=stereo -t 2 -q:a 9 -acodec aac #{Capybara.save_path}/silent_2.aac") unless File.exist?("#{Capybara.save_path}/silent_2.aac")
      system("ffmpeg -i #{Capybara.save_path}/silent_2.aac -ar 44100 -ac 2 -c:a aac -b:a 192k #{Capybara.save_path}/silent_normalized_2.aac") unless File.exist?("#{Capybara.save_path}/silent_normalized_2.aac")

      # Open file list for concatenation
      File.open("#{Capybara.save_path}/file_list.txt", 'w') do |file|
        image_files.each do |image|
          before_image = image
          after_image = image.sub('_before', '_after')
          audio = image.sub('_before', '').sub('.png', '.aac')
          label = image.split('/').last.split('_before_').first
          hash = image.split('_').last.split('.').first

          puts "label: #{label}"
          puts "before_image: #{before_image}"
          puts "after_image: #{after_image}"
          puts "audio: #{audio}"
          puts "hash: #{hash}"

          # Normalize audio parameters for each segment
          system("ffmpeg -i #{audio} -ar 44100 -ac 2 -c:a aac -b:a 192k #{Capybara.save_path}/#{label}_audio_normalized_#{hash}.aac") unless File.exist?("#{Capybara.save_path}/#{label}_audio_normalized_#{hash}.aac")

          # Generate individual video for each image/audio pair with normalized audio
          system("ffmpeg -loop 1 -i #{before_image} -i #{Capybara.save_path}/silent_normalized_2.aac -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest #{Capybara.save_path}/#{label}_before.mp4") if File.exist?(after_image)
          system("ffmpeg -loop 1 -i #{before_image} -i #{Capybara.save_path}/#{label}_audio_normalized_#{hash}.aac -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest #{Capybara.save_path}/#{label}_during.mp4")
          system("ffmpeg -loop 1 -i #{after_image} -i #{Capybara.save_path}/silent_normalized_2.aac -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest #{Capybara.save_path}/#{label}_after.mp4") if File.exist?(after_image)

          # Add entries to file list for concatenation
          file.puts("file '#{label}_before.mp4'") if File.exist?(after_image)
          file.puts("file '#{label}_during.mp4'")
          file.puts("file '#{label}_after.mp4'") if File.exist?(after_image)
        end

        # Add 2 extra seconds of silence at the end using the last image
        last_image = image_files.last
        system("ffmpeg -loop 1 -i #{last_image} -i #{Capybara.save_path}/silent_normalized_2.aac -c:v libx264 -pix_fmt yuv420p -c:a aac -b:a 192k -shortest #{Capybara.save_path}/finale.mp4")
        file.puts("file 'finale.mp4'")
      end

      # Concatenate all the individual video segments into a final video
      system("ffmpeg -f concat -safe 0 -i #{Capybara.save_path}/file_list.txt -c:v copy -c:a aac -b:a 192k #{Capybara.save_path}/#{name.sub('test_', '')}.mp4")
    end
  end
end
# rubocop:enable Lint/Debugger
