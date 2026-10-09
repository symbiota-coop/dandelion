# Dandelion

Dandelion (canonical install https://dandelion.events) is a Ruby/Mongo app based on the Padrino framework, which is in turn based on Sinatra. (It is NOT a Rails app.)

The ORM is Mongoid, not ActiveRecord.

## Crucial restrictions

- Never attempt to access ENV vars on Render.
- Never attempt to write to the production database.

## Cloud agents (Cursor, Claude Code)

Shared setup lives in `script/agent-env/`: `system-deps.sh` (apt packages, MongoDB), `install.sh` (bundle install, `.env` files) and `start-services.sh` (starts MongoDB).

- Cursor: `.cursor/environment.json` and `.cursor/Dockerfile`. After boot, `start` forks Mongo; a `web` terminal keeps `foreman start -e .env web` running (Puma on port 3000, logs in that session).
- Claude Code on the web: a `SessionStart` hook in `.claude/settings.json` runs `.claude/remote-setup.sh`. Project MCP servers come from the committed `.mcp.json`, whose `${VAR}`s are filled from the cloud environment's variables (and from your shell locally). Other tools don't read it, so each has its own committed copy of the same servers, with secrets read from the environment rather than written in: `.cursor/mcp.json` (`${env:VAR}`), `.codex/config.toml` (`env_vars` and `bearer_token_env_var`; Codex only reads it in trusted projects) and `.opencode/opencode.json` (`{env:VAR}`). Only edit `.mcp.json`, then run `rake mcp:sync` to write the others. Variables in `.mcp.json` can't have defaults (`${VAR:-x}`), as the others can't express them. Cursor cloud agents don't read any repo MCP file; their MCP servers are set up in the Cursor dashboard
- MongoDB MCP: `.mcp.json` runs `mongodb-atlas-mcp-remote`, a proxy to the Atlas Managed MCP Server (`https://mcp.mongodb.com`). `MDB_MCP_API_CLIENT_ID` and `MDB_MCP_API_CLIENT_SECRET` must come from an Atlas **MCP configuration**, not an ordinary Atlas service account: the latter gets a token but the server returns 403 (`CLIENT_HTTP_NOT_IMPLEMENTED`). The configuration has read-only roles (`GROUP_READ_ONLY` and `GROUP_DATA_ACCESS_READ_ONLY`). There is no Atlas UI for MCP configurations: a Project Owner creates them with the Admin API (`POST /api/atlas/v2/groups/{groupId}/mcpConfigs` with `mcpConfigName` and `roles`, then `POST .../mcpConfigs/{mcpConfigId}/secrets` with `secretExpiresAfterHours`, `Accept: application/vnd.atlas.2025-03-12+json`) or `atlas api remoteMcpConfigurations`. The secret is shown only once. The server lists write tools (`insert-many`, `update-many`, `delete-many`, `drop-*`, `atlas-create-*`); never call them

- Browsing the app with Playwright (Claude Code on the web): Chromium ignores `HTTPS_PROXY`, so pass it or CDN assets (jQuery etc.) won't load and nothing works: `chromium.launch({ executablePath: process.env.BROWSER_PATH, args: ['--proxy-server=' + process.env.HTTPS_PROXY] })`. Don't use Playwright's `proxy` option: it sends localhost through the proxy too, which rejects it. The setup script trusts the proxy's CA in Chromium's NSS store (`~/.pki/nssdb`); never ignore certificate errors instead. Cuprite gets the proxy from `test/test_config.rb`
- Run `foreman run bundle exec rake db:seed` to seed the database
- Run `foreman start -e .env web` to start the web process if it is not already running. Both cloud agents start it on boot: Cursor in its `web` terminal, and Claude Code on the web in the background with logs in `log/web.log`. Puma takes about 20 seconds to boot, so if port 3000 isn't answering yet, check the log or wait rather than starting a second copy
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
- CKEditor is our own build in `ckeditor/`, on CKEditor 37.1.0: 38 and later show a Powered by CKEditor badge under the GPL. Never edit `app/assets/javascripts/ext/ckeditor.js`: change `ckeditor/src/ckeditor.js` and run `rake ckeditor:build` (needs Node)
- `lib/form_builder.rb` defines the `_block` helpers like `text_block`, `wysiwyg_block` etc. `lib/param_helpers.rb` runs `blanks_to_nils!` on `params` so we can just do `if params[:x]` (no need for `if params[:x].present?`).
- Do not use `.presence`
- Controllers are `Dandelion::App.controller` blocks with `erb` / `partial` / `cp` — no `before_action`, strong params, or `render`

## Design

The design guide (`/design`, `app/views/design.erb`) shows the colours, type, spacing, components and their classes. Check it before styling anything, and keep it up to date when you change them. The rules it doesn't spell out:

- Stylesheets are plain CSS. Never edit `bootstrap5.css` (compiled vendor CSS): override Bootstrap in `app.css`, or change its variables in `bootstrap5.scss` and run `rake bootstrap:build` (needs Node). Page-specific styles go in their own file loaded only by those pages (e.g. `docs.css`, `messages.css`)
- Bootstrap 5 with jQuery: use `data-bs-*` attributes, logical spacing/alignment (`ms-*`, `me-*`, `text-end`, `float-start`), `form-select` on selects and `mb-3` between fields
- Filter forms above lists and tables use `.form-inline` and `.form-group` (kept in `app.css`) inside `.searchForm`; add `.submitOnChange` to submit when a field changes. Date fields take `.datepicker` or `.datetimepicker`, which `forms.js` wires up
- Tooltips are `data-bs-toggle="tooltip"` and a `title`; `app.js` handles them for the whole page, so content loaded later needs no setup
- To show and hide elements from JS, start them hidden with `style="display: none"` and use jQuery `.show()` / `.hide()` / `.toggle()`, not `d-none` with `addClass` / `removeClass` (Bootstrap's `d-*` classes are `!important`). Keep `d-none d-md-block` and friends for purely responsive hiding
- Success is the theme colour, so use `-primary`, never `-success`. Badges are `badge text-bg-*`; there is no `.label` and no `badge-*` colour class
- Colours, radii and shadows come from tokens (`--theme-*`, `--color-*`, `--bs-gray-*`, `--hairline`, Bootstrap's radius and shadow variables and classes), never hex values, custom values or new translucent tints, so organisation themes follow
- Motion: shows where things come from and go, and is otherwise kept out of the way. State changes fade over `--transition-fast`; things that float (dropdown menus, the confirm popover, flash toasts) fade in over `--transition-enter`, moving at most `--space-2xs`; modals keep Bootstrap's slide; chevrons on things that open in place turn. Animate only colours, shadows, masks, opacity, `translate` and `rotate`; nothing bounces, loops, scales or reveals on scroll
- Spacing comes from the scale: Bootstrap's spacing utilities in markup, `--space-*` tokens in CSS, never px or off-scale rem. Other sizes are in rem (or em); px only for hairlines, shadows, the focus ring, breakpoints and Google Maps overrides
- Avatars: `partial :'accounts/square', locals: { account:, size: :xs }` (`:xs` to `:2xl`, default `:sm`, or `:fill`). For a bare `<img>` of an account, use `class="avatar avatar-sm"` rather than a width
- `event_details.css` and `email.css` are inlined into emails, so they can't use CSS custom properties (`var(--x)`)

## Dependencies

Cooldown: never use a gem or JS package version released less than 7 days ago. This guards against supply-chain attacks on freshly published versions. If a version that was just released can't be found, that's why: wait until it's a week old rather than removing or shortening the cooldown.

- Gems: the Gemfile's source has `cooldown: 7`, so Bundler enforces it
- `rake bootstrap:build` runs `npm install` with `--before` set to 7 days ago
- `ckeditor/` installs from its `yarn.lock`. Yarn 1 has no cooldown, so when refreshing the lockfile (`yarn upgrade`), check the new versions' release dates (`npm view <package> time`) and pin back any that are under a week old
- When adding or bumping a CDN package in `config/frontend_dependencies.rb`, or a version in a rake task, pick a version at least 7 days old

Ruby gems:

@Gemfile

Frontend dependencies:

@app/views/layouts/_dependencies.erb
@config/frontend_dependencies.rb
