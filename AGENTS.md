# Dandelion

Dandelion is a Ruby/Mongo app based on the Padrino framework, which is in turn based on Sinatra. (It is NOT a Rails app.)

The ORM is Mongoid, not ActiveRecord.

## Cursor Cloud Agent

Cursor Cloud Agent setup lives in `.cursor/environment.json`.

The Cursor image installs Ruby, Bundler, Foreman, MongoDB, Chromium, and ImageMagick. The start command runs MongoDB.

- Run `foreman run bundle exec rake db:seed` to seed the database
- Run `foreman start -e .env web` to start the web process
- Login with `SEED_ACCOUNT_EMAIL` and `SEED_ACCOUNT_PASSWORD` in `.env`

## Cursor Cloud specific instructions

- **Redis**: Must be running (`redis-server --daemonize yes`) before starting the web server. It's used by `Rack::Attack` for rate limiting and by `map_helper.rb` for geocode caching.
- **MongoDB**: Must be started before seeding or running the web server. Use `bash .cursor/start-services.sh` or `mongod --fork --logpath /tmp/mongod.log --dbpath /data/db --bind_ip 127.0.0.1`.
- **Google API errors during `db:seed`** are expected and harmless when no `GOOGLE_MAPS_API_KEY` is set — geocoding simply fails silently.
- **Rubocop**: The codebase has pre-existing offenses (173 as of setup). Run `foreman run -e .env bundle exec rubocop` to lint.
- **Test a single file**: `env -u BUNDLE_PATH foreman run -e .env.test bundle exec ruby -I test test/<name>_test.rb` — tests start their own Puma on port 8020.
- **Chromium** is needed for Capybara/Cuprite integration tests. Ensure `BROWSER_PATH` points to the chromium binary.

## Documentation

You can find documentation at app/views/docs/md. Keep it up to date.

## Files in lib

Files in lib are auto-loaded by Padrino.load!. No explicit require is necessary.

## Mongo

We set `Mongoid.raise_not_found_error = false` in `boot.rb` so `Model.find(id)` returns `nil` for invalid ids.

Nil booleans are converted to false using `after_initialize :convert_nil_booleans_to_false` and `before_validation :convert_nil_booleans_to_false`.

Use `scope.and` rather than `scope.where`.

Please note that Mongo indexes are created directly in the database, and are not defined in model files.

## Tests

Always ask permission before running tests.

Never attempt to run the full test suite.

IMPORTANT: Use the following command structure to test a single file:

`env -u BUNDLE_PATH foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb`

On Codex, run this outside the sandbox.

## Dependencies

Ruby gems: 

@Gemfile

Frontend dependencies:

@app/views/layouts/_dependencies.erb
@lib/frontend_dependencies.rb
