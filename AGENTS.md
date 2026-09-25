# Dandelion

Dandelion (canonical install https://dandelion.events) is a Ruby/Mongo app based on the Padrino framework, which is in turn based on Sinatra. (It is NOT a Rails app.)

The ORM is Mongoid, not ActiveRecord.

## Crucial restrictions

- Never attempt to access ENV vars on Render.
- Never attempt to write to the production database.

## Cursor Cloud Agent

Cursor Cloud Agent setup lives in `.cursor/environment.json`.

The Cursor image installs Ruby, Bundler, Foreman, MongoDB, Chromium, and ImageMagick. The start command runs MongoDB.

- Run `foreman run bundle exec rake db:seed` to seed the database
- Run `foreman start -e .env web` to start the web process
- Login with `SEED_ACCOUNT_EMAIL` and `SEED_ACCOUNT_PASSWORD` in `.env`

## Mongo

- We set `Mongoid.raise_not_found_error = false` in `boot.rb` so `Model.find(id)` returns `nil` for invalid ids
- Nil booleans are converted to false using `after_initialize :convert_nil_booleans_to_false` and `before_validation :convert_nil_booleans_to_false`
- Use `validates_presence_of`, not `validates :name, presence: true`
- Put field cleanup and `errors.add` in `before_validation`, not `validate do`
- Use `belongs_to_without_parent_validation`, not Mongoid `belongs_to` (its parent check fails when the parent is only in memory)
- Use `has_many_through` for join collections, not `has_many :x, through:` (Mongoid has no `through`)
- Query filters are class methods that return `self.and(...)` so they chain (`Event.live.future`). Do not use `scope :live, -> { ... }`
- Never use Mongoid `.or` — it ORs against whatever is already in the selector (`Event.live.or(featured: true)` means live or featured). Use `self.and('$or' => [...])` so the OR is just another AND-ed filter (`Event.live.and('$or' => [...])` means live and (this or that))
- Use `scope.and` rather than `scope.where`
- Mongo indexes are created directly in the database, and are not defined in model files

## Tests

You can use the following command structure to test a single file: `foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb`

To run only certain tests in a file, add `-n /pattern/` (matches the method name, with spaces as underscores) e.g. `foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb -n /youtube_titles/`

Always ask permission before running tests. Your default posture should be to suggest only added/modified tests and any other clearly relevant tests, unless the change is substantial, in which case it may be appropriate to run whole files. Never attempt to run the full test suite.

`@` instance variables come from helpers (`create_organisation`, `create_event`, `create_gathering`, `create_full_event_hierarchy`, and file-local setup methods). Anything created inline in a test is a local. Use `create_event(as: :event1)` when a test needs more than one event.

## Everything else

- You can find documentation at app/views/docs/md. Keep it up to date.
- Files in lib are auto-loaded by Padrino.load!. No explicit require is necessary.
- The `activate_tools` gem defines the `_block` helpers like `text_block`, `wysiwyg_block` etc. It also runs `blanks_to_nils!` on `params` so we can just do `if params[:x]` (no need for `if params[:x].present?`).
- Do not use `.presence`
- Controllers are `Dandelion::App.controller` blocks with `erb` / `partial` / `cp` — no `before_action`, strong params, or `render`

## Dependencies

Ruby gems: 

@Gemfile

Frontend dependencies:

@app/views/layouts/_dependencies.erb
@lib/frontend_dependencies.rb
