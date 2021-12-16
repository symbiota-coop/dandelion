workers Integer(ENV['WEB_CONCURRENCY'] || 2)
threads Integer(ENV['MIN_THREADS'] || 2), Integer(ENV['MAX_THREADS'] || 2)
port ENV['PORT'] || 3000
environment ENV['RACK_ENV']

preload_app!
