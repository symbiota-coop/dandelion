# Dandelion

Dandelion is a Ruby/Mongo app based on the Padrino framework, which is in turn based on Sinatra. (It is NOT a Rails app.)

The ORM is Mongoid, not ActiveRecord.

## Cursor Cloud Agent

Cursor Cloud Agent setup lives in `.cursor/environment.json`.

The Cursor image installs Ruby, Bundler, Foreman, MongoDB, Chromium, and ImageMagick.

The install command runs `bundle install`, copies `.env.example` to `.env` when needed, copies `.env.test.example` to `.env.test` when needed, and creates local runtime directories.

The start command runs MongoDB.

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
