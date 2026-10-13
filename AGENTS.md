# Dandelion

Dandelion (canonical install https://dandelion.events) is a Ruby/Mongo app based on the Padrino framework, which is in turn based on Sinatra. (It is NOT a Rails app.)

The ORM is Mongoid, not ActiveRecord.

Code map: controllers in `app/controllers`, views in `app/views`, CSS/JS in `app/assets`; models in `models`, with shared model code in `models/concerns`; view helpers in `app/helpers`; other library code in `lib` (form builder, payments, mail, auth); boot and config in `config`; rake tasks in `tasks`; tests in `test`. Background jobs use delayed_job (`handle_asynchronously` or `.delay`), run by the `worker` process in `Procfile`.

## Many agents

Dandelion is built with many coding agents (Claude Code, Codex, Cursor, opencode and others), on our own machines and in the cloud, and often several at once in the same checkout. It's set up so that any of them can work on it equally well, with nothing that only works for one:

- Instructions: this file is the instructions for every agent. Write what an agent needs to know here, for any agent, rather than in a tool's own file (`CLAUDE.md`, `.cursor/rules`, `.github/copilot-instructions.md`...), which other agents wouldn't read and which would drift from this one. Claude Code reads this file itself when there's no `CLAUDE.md`
- Rules: a rule that code can check gets a check (Custom checks), not just a line here, so it holds whichever agent wrote the code. The checks run where every agent passes: the pre-commit hook (Committing), as every agent commits with git, and CI. Don't rely on one tool's hooks or settings to enforce a rule
- Setup: `script/agent-env/` installs and starts everything for any environment, and each tool's own config only calls it (Cloud agents)
- MCP servers: defined once in `.mcp.json` and copied into each tool's format by `rake mcp:sync` (Cloud agents)
- Shared checkouts: other sessions may be editing the same files, so commit only your own changes (Committing)
- Automation: the daily bug reviews in `.github/workflows` run Claude, Codex and Cursor on the same prompt (`.github/prompts`, `.github/actions`), with their models in `.github/models.env`

## Custom checks

CI fails on each rule below, and each names its check. When you add a rule to this file that code can check, add a check for it, list it here, and add cases to `test/lint_test.rb`, which tests our checks (each cop's `@example`, good and bad, is tested as it stands). It doesn't boot the app, so it runs without foreman: `bundle exec ruby -I test test/lint_test.rb`, and CI's lint job runs it. Disable a check only where its rule genuinely doesn't apply, and say why in the comment.

### RuboCop

Our cops (`Dandelion/...`) are in `.rubocop/dandelion/`, and also run on the Ruby in templates through erb_lint (its `RubocopTags` linter, `.erb_linters/rubocop_tags.rb`, which also checks the conditions of `<% if %>`, `<% unless %>` and `<% elsif %>` tags). Disable one on a line with `# rubocop:disable Dandelion/... -- reason`.

- `Dandelion/MongoidOr`: Never use Mongoid `.or` — it ORs against whatever is already in the selector (`Event.live.or(featured: true)` means live or featured). Use `self.and('$or' => [...])` so the OR is just another AND-ed filter (`Event.live.and('$or' => [...])` means live and (this or that))
- `Dandelion/MongoidIndex`: Mongo indexes are created directly in the database, not declared in models with Mongoid's `index`. It checks `models`
- `Dandelion/MongoidScope`: Query filters are class methods that return `self.and(...)` so they chain (`Event.live.future`). Do not use `scope :live, -> { ... }`
- `Dandelion/MongoidWhere`: Use `scope.and` rather than `scope.where` (a JavaScript `$where` string, `where('this.paid < this.requested_contribution')`, is the exception, as `.and` can't take one)
- `Dandelion/BelongsTo`: Use `belongs_to_without_parent_validation`, not Mongoid `belongs_to` (its parent check fails when the parent is only in memory)
- `Dandelion/HasManyThrough`: Use `has_many_through` for join collections, not `has_many :x, through:` (Mongoid has no `through`)
- `Dandelion/ValidatesPresence`: Use `validates_presence_of`, not `validates :name, presence: true`
- `Dandelion/ValidateBlock`: Put field cleanup and `errors.add` in `before_validation`, not `validate do`
- `Dandelion/ParamsBlank`: `lib/param_helpers.rb` runs `blanks_to_nils!` on `params`, so blank values are already nil: just do `if params[:x]` (or `unless`), with no `.present?` or `.blank?`
- `Dandelion/Presence`: Don't use `.presence`, on `params` or anywhere else
- `Dandelion/ErrorReporting`: Report rescued errors with `ErrorReporting.capture_exception(e, context:, tags:)`, not `Sentry.capture_exception`
- `Dandelion/RailsController`: Controllers are `Dandelion::App.controller` blocks (Padrino), not Rails controllers: `before do`, not `before_action`; `erb`, `partial` or `cp`, not `render`; `redirect`, not `redirect_to`; `provides:` and `content_type`, not `respond_to`; and no strong parameters: pass `params[:x]` through `mass_assigning(params[:x], Model)`. It checks `app/controllers`
- `Dandelion/CapybaraHasNoAfterClick`: Straight after a click, assert something on the new page before checking something isn't there (`has_no_*`, `assert_no_*`), or that check can pass on the old page. A click whose confirm is dismissed (`dismiss_confirm`) doesn't leave the page. It checks `test`
- `Dandelion/TestInstanceVariable`: In a test, `@` variables come from helpers (`create_organisation`, `create_event`, `create_gathering`, `create_full_event_hierarchy`, and file-local setup methods); anything created inline in a test is a local. A test may refresh a variable one of its file's helpers sets. It checks `test`
- `Dandelion/CapybaraCurrentPath`: Check the page's path with `assert page.has_current_path?(...)` (with `ignore_query: true` to compare the path alone, or `url: true` for the whole URL), which waits for the page: `current_path` and `current_url` don't, so straight after a click they can still be the old page's. It checks `test`
- `Dandelion/CapybaraRefuteHas`: To check something isn't on the page, use `assert page.has_no_css?` (`has_no_content?`, `has_no_link?`, `has_no_title?`...), never `refute page.has_css?`: the `has_` form waits the full 10 s `default_max_wait_time` for it to appear before passing

### erb_lint

Our linter, `DesignClasses`, is in `.erb_linters/design_classes.rb`. Disable it on a line with `<%# erb_lint:disable DesignClasses: reason %>`.

- `DesignClasses`: To show and hide elements from JS, start them hidden with `style="display: none"` and use jQuery `.show()` / `.hide()` / `.toggle()`, not `d-none` with `addClass` / `removeClass` (Bootstrap's `d-*` classes are `!important`). Keep `d-none d-md-block` and friends for purely responsive hiding
- `DesignClasses`: Success is the theme colour, so use `-primary`, never `-success`. Badges are `badge text-bg-*`; there is no `.label` and no `badge-*` colour class
- `DesignClasses`: Bootstrap 5, not 4: `data-bs-*` attributes and logical spacing and alignment (`ms-*`, `me-*`, `ps-*`, `pe-*`, `text-end`, `float-start`). `config/bootstrap4_leftovers.json` lists the Bootstrap 4 classes and attributes it flags, with what replaces each; add one there if you find another
- `DesignClasses`: Selects take `form-select` (`<select>` tags and `select_tag`; the form builder's `select_block` adds it), even ones Select2 replaces, so they look right until it loads

### ESLint

Our rules are in `eslint.config.mjs`. Disable one with `// eslint-disable-next-line <rule> -- reason`.

- `no-restricted-syntax`: The `DesignClasses` rules above (showing and hiding; `-success`, `badge-*` and `.label`; Bootstrap 4 leftovers; `form-select`), in the strings and template literals of `app/assets/javascripts`

### Stylelint

Our rules are in `stylelint.config.mjs`. Disable one with `/* stylelint-disable <rule> -- reason */` and `/* stylelint-enable <rule> */`.

- `declaration-property-value-disallowed-list` and `color-named`: Colours come from tokens (`--theme-*`, `--color-*`, `--bs-gray-*`, `--hairline`...), so organisation themes follow: never hex values, `rgb()`/`hsl()` of numbers or named colours, which the check allows only where a custom property is defined. Translucent black and white are `rgba(var(--bs-black-rgb), a)` and `rgba(var(--bs-white-rgb), a)`; don't add other translucent tints beyond those the design guide lists (not checked)
- `declaration-property-value-disallowed-list`: Radii come from Bootstrap's variables (`--bs-border-radius`, `-sm`, `-lg`, `-xl`, `-pill`), or are 0, 50% or inherit. A shadow with blur is an elevation, so it's one of Bootstrap's (`--bs-box-shadow-sm`, `--bs-box-shadow`, `--bs-box-shadow-lg` or the `shadow-*` classes); unblurred rings (the focus ring, hairline rings, image overlays) are fine. The check flags lengths in radii and blurred shadows
- `declaration-property-unit-disallowed-list`: Spacing comes from the scale: Bootstrap's spacing utilities in markup, `--space-*` tokens in CSS, never px. Off the scale only to size a control to match another or to line up with a fixed layout dimension (the design guide's Spacing lists them). Other sizes are in rem (or em); px only for hairlines, shadows, the focus ring, breakpoints and Google Maps overrides. The check flags px in margins, padding, gaps, insets (`inset*`, `top`, `right`, `bottom`, `left`) and font sizes
- `declaration-property-value-disallowed-list`: Motion: transitions animate only colours, shadows, masks, opacity, `translate` and `rotate` (not `all`, `transform`, `scale` or sizes), over `--transition-fast` or `--transition-enter` rather than a duration of their own, and only loading indicators loop (`infinite`). Loading indicators, which may loop on their own timing, disable it where they are, as do the guide's two older exceptions (the quick theme colours and feedback stars grow on hover); don't add more
- `declaration-property-value-disallowed-list` (override for `event_details.css` and `email.css`): These two are inlined into emails, so they can't use CSS custom properties (`var(--x)`). The colour, radius, shadow and spacing checks above don't apply to them

### Other checks

Rules no linter covers, checked by `test/lint_test.rb` (which CI's lint job runs) or `script/lint` (which the pre-commit hook runs). Each names its check.

- `test_mcp_copies_match_mcp_json`: `.cursor/mcp.json`, `.opencode/opencode.json` and `.codex/config.toml` are copies of `.mcp.json`: only edit `.mcp.json`, then run `rake mcp:sync` (Cloud agents)
- `test_ci_runs_every_test_file`: CI's test jobs, one per test file, are listed in `.github/workflows/ruby.yml`: add a new test file there (Tests)
- `test_every_disable_says_why`: every disable comment gives its reason, after `--` (or after `Linter:` for erb_lint), as each linter's section shows
- `test_dependency_versions_are_exact`: the root `package.json`, the CDN packages (`config/frontend_dependencies.rb`, `layouts/_dependencies.erb`) and the packages rake tasks install name exact versions, so none arrives unchosen (Dependencies)
- `test_ckeditor_stays_on_37`: CKEditor stays on 37 (Build/vendored code)
- `script/lint`: `bootstrap5.css` and `ext/ckeditor.js` are built (Build/vendored code), so a commit that changes one without its source (`bootstrap5.scss`, `ckeditor/`, or their rake task) fails

## Committing

Commit only the changes you made: other sessions may be editing the same checkout, so stage your files by name rather than with `git add -A` or `git commit -a`.

`script/lint` runs our linters, RuboCop, erb_lint, ESLint and Stylelint, each on the files of its kind. CI's lint job (`.github/workflows/ruby.yml`) runs it too, so it is the one place their commands and flags are set: change a linter's flags or add a linter there, not in the workflow. Run it on the files you added or changed as you go, and fix what it reports:

```bash
script/lint <files>
```

If a linter's config is among them (`.rubocop.yml`, `.rubocop/`, `.erb_lint.yml`, `.erb_linters/`, `eslint.config.mjs`, `stylelint.config.mjs`, `package.json`), it runs that linter on everything, as CI does; `script/lint --all` runs them all, and `--only <linter>` just one. Run `npm ci` first if `node_modules` is missing.

The pre-commit hook (`.githooks/pre-commit`) runs `script/lint --staged`, which lints the staged version of each staged file, so another session's unstaged edits don't count. Git runs it once `core.hooksPath` is `.githooks`, which `script/agent-env/install.sh` sets; in a checkout of your own, run `git config core.hooksPath .githooks` once. If it fails, fix the offenses (or disable a check where its rule genuinely doesn't apply, as above) and commit again. Never skip it with `--no-verify`.

## Crucial restrictions

- Never attempt to access ENV vars on Render.
- Never attempt to write to the production database.

## Cloud agents (Cursor, Claude Code)

Shared setup lives in `script/agent-env/`: `system-deps.sh` (apt packages, Chromium, MongoDB and Node), `ruby.sh` (the Gemfile's Ruby, for images without it), `browser-path.sh` (prints the Chromium for `BROWSER_PATH`), `install.sh` (bundle install, npm ci, `.env` files, the pre-commit hook), `start-services.sh` (starts MongoDB) and `start-web.sh` (starts Puma in the background, logging to `log/web.log`, for environments with no terminal to keep it in). A tool's own setup only calls these, plus anything that applies to that tool alone (Claude Code's proxy CA and `CLAUDE_ENV_FILE`).

- Cursor: `.cursor/environment.json` and `.cursor/Dockerfile`. After boot, `start` forks Mongo; a `web` terminal keeps `foreman start -e .env web` running (Puma on port 3000, logs in that session). That terminal is a tmux session, so `system-deps.sh` installs tmux.
- Claude Code on the web: a `SessionStart` hook in `.claude/settings.json` runs `.claude/remote-setup.sh`. Project MCP servers come from the committed `.mcp.json`, whose `${VAR}`s are filled from the cloud environment's variables (and from your shell locally). Other tools don't read it, so each has its own committed copy of the same servers, with secrets read from the environment rather than written in: `.cursor/mcp.json` (`${env:VAR}`), `.codex/config.toml` (`env_vars` and `bearer_token_env_var`; Codex only reads it in trusted projects) and `.opencode/opencode.json` (`{env:VAR}`). Only edit `.mcp.json`, then run `rake mcp:sync` to write the others. Variables in `.mcp.json` can't have defaults (`${VAR:-x}`), as the others can't express them. Cursor cloud agents don't read any repo MCP file; their MCP servers are set up in the Cursor dashboard
- MongoDB MCP: `.mcp.json` runs `mongodb-atlas-mcp-remote`, a proxy to the Atlas Managed MCP Server (`https://mcp.mongodb.com`), with read-only access to production. The server lists write tools (`insert-many`, `update-many`, `delete-many`, `drop-*`, `atlas-create-*`); never call them
- Browsing the app with Playwright (Claude Code on the web): Chromium ignores `HTTPS_PROXY`, so pass it or CDN assets (jQuery etc.) won't load and nothing works: `chromium.launch({ executablePath: process.env.BROWSER_PATH, args: ['--proxy-server=' + process.env.HTTPS_PROXY] })`. Don't use Playwright's `proxy` option: it sends localhost through the proxy too, which rejects it. The setup script trusts the proxy's CA in Chromium's NSS store (`~/.pki/nssdb`); never ignore certificate errors instead. Cuprite gets the proxy from `test/test_config.rb`
- Run `foreman run bundle exec rake db:seed` to seed the database
- Run `foreman start -e .env web` to start the web process if it is not already running. Both cloud agents start it on boot: Cursor in its `web` terminal, and Claude Code on the web in the background (`script/agent-env/start-web.sh`) with logs in `log/web.log`. Puma takes about 20 seconds to boot, so if port 3000 isn't answering yet, check the log or wait rather than starting a second copy
- Login with `SEED_ACCOUNT_EMAIL` and `SEED_ACCOUNT_PASSWORD` in `.env`

## Mongo

- We set `Mongoid.raise_not_found_error = false` in `boot.rb` so `Model.find(id)` returns `nil` for invalid ids
- Nil booleans are converted to false using `after_initialize :convert_nil_booleans_to_false` and `before_validation :convert_nil_booleans_to_false`
- Mongo indexes are created directly in the database, and are not defined in model files (`Dandelion/MongoidIndex`)
- `Event.hinted(index_name)` makes MongoDB skip query planning, for queries it can't cache a plan for (e.g. an organisation's events `$or`, ~300 ms to plan: `events_including_cohosted.hinted(Event::HOSTS_INDEX)`). Hint only at call sites that need it, since it overrides more selective indexes. Index existence is checked once per process: dropping a hinted index needs a restart (or the queries fail), renaming one a code change
- Unique indexes:
  - Back every `validates_uniqueness_of` with a unique index
  - If nil is allowed, filter it with `partialFilterExpression: { field: { $type: '<BSON type>' } }`, never `$exists: true` (Mongoid stores explicit nulls, which would clash). If nil isn't allowed, use a plain unique index with no filter, but only if every document has the field: documents missing it count as nulls and would clash
  - Beside every `$type`-filtered index, keep a plain non-unique index on the same fields (e.g. `slug_1` beside `slug_1_unique`) unless another plain index starts with them: the planner can't use the filtered one for plain `{ field: x }` queries, including the validation's own. Never drop that plain index, and don't add a `$type` condition to the validation instead
  - Random values that can't clash, like UUIDs and other `SecureRandom` tokens (`token`, `ics_key`, `sign_in_token`, `DragonflyJob#uid`), get a unique index but no `validates_uniqueness_of` or `exists?` loop, which would cost a query on every create. Short or derived values (`evm_secret`, `DragonflyJob#signature`) keep the validation
  - Check index use with the slow query log or `$indexStats` (0 ops means unused)

## Tracing

- Every request is traced, but `before_send_transaction` (`config/sentry_config.rb`) saves it to the `traces` collection (`Trace`) and returns nil: Sentry gets only errors and logs, never transactions or profiles. For performance data, query `traces` (e.g. with the MongoDB MCP), not Sentry: `name` (route), `duration_ms`, `http_status`, `release`, `started_at`
- Requests matching no route and `GET /health` aren't saved. Mongo queries become spans via `SentryMongoCommandSubscriber`
- Spans are zstd-compressed in `spans_zstd`, so Mongo queries can't read them; use `Trace#spans` in Ruby. Atlas Search pipelines and timings are also stored uncompressed in `search_spans`

## Tests

You can use the following command structure to test a single file: `foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb`

To run only certain tests in a file, add `-n /pattern/` (matches the method name, with spaces as underscores) e.g. `foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb -n /youtube_titles/`

Each test run gets its own database (`dandelion_test_<pid>`, dropped when the run ends) and a free port, set in `config/boot.rb`, so runs can go at the same time, in one checkout or several. To run several files at once, start each in its own process, e.g. `printf '%s\n' accounts events | xargs -P 2 -I{} sh -c 'foreman run -e .env.test bundle exec ruby -I test test/{}_test.rb > tmp/{}.log 2>&1'`; each browser run starts its own Chrome, so keep to 3 or 4 at once. Test files take minutes, so if your tool can run commands in the background, start test runs there and keep working until they finish. Each run saves its screenshots to `capybara/<pid>/`, kept for an hour after the run ends.

CI runs each test file as its own job, listed in `.github/workflows/ruby.yml`: add a new test file there.

Always ask permission before running tests. Your default posture should be to suggest only added/modified tests and any other clearly relevant tests, unless the change is substantial, in which case it may be appropriate to run whole files. Never attempt to run the full test suite.

`@` instance variables come from helpers, and anything created inline in a test is a local (`Dandelion/TestInstanceVariable`). Use `create_event(as: :event1)` when a test needs more than one event.

Straight after a click or submit, assert something on the new page before checking something isn't there, or that check can pass on the old page (`Dandelion/CapybaraHasNoAfterClick`; and check with `assert page.has_no_*`, as `Dandelion/CapybaraRefuteHas` says).

## Conventions

- Controllers are `Dandelion::App.controller` blocks with `erb` / `partial` / `cp` (`Dandelion/RailsController` checks for Rails habits)
- Files in lib are auto-loaded by Padrino.load!. No explicit require is necessary.
- `lib/form_builder.rb` defines the `_block` helpers like `text_block`, `wysiwyg_block` etc.
- You can find documentation at app/views/docs/md. Keep it up to date.

## Security reviews

- Every model runs `sanitize_fields` (`models/concerns/core_extensions.rb`) before validation: it strips tags and drops `<` and `>` from `name`, `title` and `subject` (`CoreExtensions::SANITIZED_FIELDS`). So a view or helper that outputs one of these unescaped (e.g. `dropdown_nav`, `ul_nav`, `"#{x.name}".html_safe`, Tribute's mention menu) is not an XSS on its own. Before reporting one, show a write path that skips validation (`set`, `update_one`, `save(validate: false)`) or a field outside that list, and check `protected_attributes`/`permitted_attributes`, which decide whether a form can set the field at all
- `<%= %>` escapes by default (Padrino `SafeErubi`); look at `<%==`, `.html_safe` and `raw` for XSS
- `lib/param_helpers.rb` strips Mongo `$` operators from form params (not from JSON request bodies)

## Build/vendored code

- CKEditor is our own build in `ckeditor/`, on CKEditor 37.1.0: 38 and later show a Powered by CKEditor badge under the GPL. Never edit `app/assets/javascripts/ext/ckeditor.js`: change `ckeditor/src/ckeditor.js` and run `rake ckeditor:build` (needs Node)
- Never edit `bootstrap5.css` (compiled vendor CSS): change Bootstrap's variables in `bootstrap5.scss` and run `rake bootstrap:build` (needs Node)

## Design

The design guide (`/design`, `app/views/design.erb`) shows the colours, type, spacing, components and their classes. Check it before styling anything, and keep it up to date when you change them. The rules it doesn't spell out are below, apart from those with a check (showing and hiding, success and badge classes, colours, spacing), which are in Custom checks:

- Stylesheets are plain CSS. Override Bootstrap in `app.css` (see Build/vendored code for changing its variables). Page-specific styles go in their own file loaded only by those pages (e.g. `docs.css`, `messages.css`)
- Bootstrap 5 with jQuery: `mb-3` between fields (its `data-bs-*` attributes, logical spacing and `form-select` are checks, under erb_lint)
- Filter forms above lists and tables use `.form-inline` and `.form-group` (kept in `app.css`) inside `.searchForm`; add `.submitOnChange` to submit when a field changes. Date fields take `.datepicker` or `.datetimepicker`, which `forms.js` wires up
- Tooltips are `data-bs-toggle="tooltip"` and a `title`; `app.js` handles them for the whole page, so content loaded later needs no setup
- Motion: shows where things come from and go, and is otherwise kept out of the way. State changes fade over `--transition-fast`; things that float (dropdown menus, the confirm popover, flash toasts) fade in over `--transition-enter`, moving at most `--space-2xs`; modals keep Bootstrap's slide; chevrons on things that open in place turn. Nothing bounces or reveals on scroll; what transitions may animate, their durations and looping are a check, under Stylelint
- Avatars: `partial :'accounts/square', locals: { account:, size: :xs }` (`:xs` to `:2xl`, default `:sm`, or `:fill`). For a bare `<img>` of an account, use `class="avatar avatar-sm"` rather than a width

## Dependencies

Cooldown: never use a gem or JS package version released less than 7 days ago. This guards against supply-chain attacks on freshly published versions. If a version that was just released can't be found, that's why: wait until it's a week old rather than removing or shortening the cooldown.

- Gems: the Gemfile's source has `cooldown: 7`, so Bundler enforces it
- `rake bootstrap:build` runs `npm install` with `--before` set to 7 days ago
- The root `package.json` is only linters: ESLint, which CI runs as `npx eslint` over `app/assets/javascripts` (`eslint.config.mjs`), and Stylelint, which it runs over `app/assets/stylesheets` (`stylelint.config.mjs`; `npm run lint` runs both). It installs from `package-lock.json` (`npm ci`): pin exact versions, and when adding or bumping one run `npm install --before=<the date a week ago>` so its own dependencies are a week old too
- `ckeditor/` installs from its `yarn.lock`. Yarn 1 has no cooldown, so when refreshing the lockfile (`yarn upgrade`), check the new versions' release dates (`npm view <package> time`) and pin back any that are under a week old
- When adding or bumping a CDN package in `config/frontend_dependencies.rb`, or a version in a rake task, pick a version at least 7 days old

Ruby gems:

@Gemfile

Frontend dependencies:

@app/views/layouts/_dependencies.erb
@config/frontend_dependencies.rb
