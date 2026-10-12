# Compile hot Ruby methods to machine code. Web only: the worker has come close to
# its memory limit, and YJIT adds up to 128 MB (Ruby builds without YJIT don't define enable)
RubyVM::YJIT.enable if defined?(RubyVM::YJIT.enable)

workers Integer(ENV['WEB_CONCURRENCY'] || 0)
threads Integer(ENV['MIN_THREADS'] || 3), Integer(ENV['MAX_THREADS'] || 3)
port ENV['PORT'] || 3000
environment ENV['RACK_ENV']

preload_app!
