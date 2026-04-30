# Dandelion

Dandelion is a Ruby/Mongo app based on the Padrino framework, which is in turn based on Sinatra. (It is NOT a Rails app.)

The ORM is Mongoid, not ActiveRecord.

## Setup instructions

- Use `ruby-build` to install `ruby`
- Install the `foreman` gem with `gem install foreman`
- Run `bundle install` to install dependencies
- Copy `.env.example` to `.env` and `.env.test.example` to `.env.test`
- Start the following services:

| Service | Start command | Notes |
|---------|--------------|-------|
| MongoDB | `mongod --fork --logpath /tmp/mongod.log --dbpath /data/db` | Must be running before app or tests |
| Redis | `sudo redis-server --daemonize yes` | Must be running for Rack::Attack |
| Web (Puma) | `foreman start -e .env web` | |
| Worker | `foreman start -e .env worker` | Background jobs (optional for dev) |

- Run `foreman run bundle exec rake db:seed` to seed the database
- Login with the account in `.env.example`

## Documentation

You can find documentation at app/views/docs/md. Keep it up to date.

## Files in lib

Files in lib are auto-loaded by Padrino.load!. No explicit require is necessary.

## Mongo

We set `Mongoid.raise_not_found_error = false` in `boot.rb` so `Model.find(id)` returns `nil` for invalid ids.

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

## Cursor Cloud specific instructions

Ruby 3.4.7 is installed at `/usr/local/ruby-3.4.7/bin` and is on the PATH via `~/.bashrc`. The `foreman` gem is installed globally via `sudo gem install foreman` (not via bundler).

Bundle path is configured locally (`vendor/bundle`) via `.bundle/config`. Use `env -u BUNDLE_PATH` prefix when running foreman commands to avoid path conflicts, as documented in the Tests section.

### Starting services

Before running the app or tests, start MongoDB and Redis:

```
sudo mkdir -p /data/db && sudo chown -R $(whoami) /data/db
mongod --fork --logpath /tmp/mongod.log --dbpath /data/db
sudo redis-server --daemonize yes
```

Then start the web server: `env -u BUNDLE_PATH foreman start -e .env web` (runs on port 3000).

### Gotchas

- The `/data/db` directory must be owned by the current user, not root. Use `sudo chown -R $(whoami) /data/db` if MongoDB fails with permission errors.
- Google Maps API errors during `db:seed` are harmless — they occur because no `GOOGLE_MAPS_API_KEY` is set.
- Tests use Capybara with Cuprite (headless Chrome). Chrome must be installed for tests to run.
- The seeded login account is `maria@symbiota.coop` / `psilocybe-caerulescens` (from `.env.example`).
