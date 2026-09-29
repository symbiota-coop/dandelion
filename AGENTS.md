# Dandelion

Dandelion (canonical install https://dandelion.events) is a Ruby/Mongo app based on the Padrino framework, which is in turn based on Sinatra. (It is NOT a Rails app.)

The ORM is Mongoid, not ActiveRecord.

## Crucial restrictions

- Never attempt to access ENV vars on Render.
- Never attempt to write to the production database.

## Cloud agents (Cursor, Claude Code)

Shared setup lives in `script/agent-env/`: `system-deps.sh` (apt packages, MongoDB), `install.sh` (bundle install, `.env` files) and `start-services.sh` (starts MongoDB).

- Cursor: `.cursor/environment.json` and `.cursor/Dockerfile`. After boot, `start` forks Mongo; a `web` terminal keeps `foreman start -e .env web` running (Puma on port 3000, logs in that session).
- Claude Code on the web: a `SessionStart` hook in `.claude/settings.json` runs `.claude/remote-setup.sh`

- Run `foreman run bundle exec rake db:seed` to seed the database
- Run `foreman start -e .env web` to start the web process if it is not already running
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
- `lib/form_builder.rb` defines the `_block` helpers like `text_block`, `wysiwyg_block` etc. `lib/param_helpers.rb` runs `blanks_to_nils!` on `params` so we can just do `if params[:x]` (no need for `if params[:x].present?`).
- Do not use `.presence`
- Stylesheets are plain CSS (no Sass). `app/assets/stylesheets/bootstrap5.css` is compiled vendor CSS: never edit it; override it in `app/assets/stylesheets/app.css`, which also holds the page layout (header, sidebar, content) and component styles. Styles only needed on certain pages go in their own file that only those pages load (e.g. `docs.css`, loaded by the docs views, and `messages.css`, loaded by the messages page), not in the site-wide dependencies
- Use `badge badge-*` for counts and short statuses (Sold out, Locked, Refunded), and `label label-*` for tags, linked entities and amounts (event tags, teams, revenue figures)
- The UI is Bootstrap 5 with jQuery, so Bootstrap's jQuery plugins still work (`$(el).tooltip()`, `$('#modal').modal('show')`). Use `data-bs-*` attributes (`data-bs-toggle="tooltip"`), logical spacing and alignment (`ms-*`, `me-*`, `text-end`, `float-start`) and `form-select` on selects. Space fields with `mb-3` (activate-tools' blocks do); `.form-inline` and `.form-group` were dropped from Bootstrap 5 but are kept in `app.css` for the filter forms above lists and tables. `badge-*` and `label-*` are our own classes too
- To change Bootstrap variables, edit `app/assets/stylesheets/bootstrap5.scss` and run `rake bootstrap:build` (needs Node), which regenerates `bootstrap5.css` and `app/assets/javascripts/ext/bootstrap.bundle.min.js`
- `event_details.css` and `email.css` are inlined into emails, so they can't use CSS custom properties (`var(--x)`)
- Controllers are `Dandelion::App.controller` blocks with `erb` / `partial` / `cp` — no `before_action`, strong params, or `render`

## Dependencies

Ruby gems: 

@Gemfile

Frontend dependencies:

@app/views/layouts/_dependencies.erb
@lib/frontend_dependencies.rb
