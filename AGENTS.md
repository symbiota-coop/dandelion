# Dandelion

Dandelion (canonical install https://dandelion.events) is a Ruby/Mongo app based on the Padrino framework, which is in turn based on Sinatra. (It is NOT a Rails app.)

The ORM is Mongoid, not ActiveRecord.

Code map: controllers in `app/controllers`, views in `app/views`, CSS/JS in `app/assets`; models in `models`, with shared model code in `models/concerns`; view helpers in `app/helpers`; other library code in `lib` (form builder, payments, mail, auth); boot and config in `config`; rake tasks in `tasks`; tests in `test`. Background jobs use delayed_job (`handle_asynchronously` or `.delay`), run by the `worker` process in `Procfile`.

## Crucial restrictions

The rules that must never be broken, whatever the task. The section each names says why:

- Never attempt to access ENV vars on Render
- Never attempt to write to the production database, including with the MongoDB MCP's write tools (MCP servers)
- Never skip the pre-commit hook with `--no-verify` (Linting)
- Never stage or commit another session's changes: no `git add -A` or `git commit -a` (Committing)
- Never attempt to run the full test suite (Tests)
- Never edit built or vendored files: `ext/ckeditor.js`, `bootstrap5.css`, the jQuery UI builds (Build/vendored code)
- Never use a gem or JS package version released less than 7 days ago (Dependencies)

## Many agents

Dandelion is built with many coding agents (Claude Code, Codex, Cursor, opencode and others), on our own machines and in the cloud, and often several at once in the same checkout. It's set up so that any of them can work on it equally well, with nothing that only works for one:

- Instructions: this file is the instructions for every agent. Write what an agent needs to know here, for any agent, rather than in a tool's own file (`CLAUDE.md`, `.cursor/rules`, `.github/copilot-instructions.md`...), which other agents wouldn't read and which would drift from this one. Claude Code reads this file itself when there's no `CLAUDE.md`
- Memories: don't save what you learn to a tool's own memory (Claude Code's memory files, Cursor's or Codex's memories...), which only that tool reads, on one machine. If it's worth remembering, add it here
- Rules: a rule that code can check gets a check (Linting), not just a line here, so it holds whichever agent wrote the code. The checks run where every agent passes: the pre-commit hook (Linting), as every agent commits with git, and CI. Don't rely on one tool's hooks or settings to enforce a rule
- Setup: `script/agent-env/` installs and starts everything for any environment, and each tool's own config only calls it (Cloud agents)
- MCP servers: defined once in `.mcp.json` and copied into each tool's format by `rake mcp:sync` (MCP servers)
- Shared checkouts: other sessions may be editing the same files, so commit only your own changes (Committing)
- Automation: workflows in `.github/workflows` run Claude, Codex, Cursor and opencode on daily bug reviews, and Claude on new issues and on drafting replies to users' emails. Read `.github/workflows/README.md` before changing one, its prompt (`.github/prompts`) or its models (`.github/models.env`). This repo's workflow logs are public, so keep emails and query results out of anything its workflows print

## Committing

Commit only the changes you made: other sessions may be editing the same checkout, so stage your files by name rather than with `git add -A` or `git commit -a`.

## Linting

`script/lint` runs our linters, each on the files of its kind: RuboCop, with our own cops (`.rubocop/dandelion/`), also on the Ruby in templates through erb_lint; erb_lint (`.erb_linters/`); ESLint (`eslint.config.mjs`) and Stylelint (`stylelint.config.mjs`), also on the scripts and styles in templates; Herb (`.herb.yml`); zizmor and actionlint (`.github/actionlint.yaml`) on `.github`; ShellCheck; and `test/lint_test.rb`, which tests our checks and the rules no linter covers. Each rule's message says what to do instead, and its config or code says why. CI's lint job runs it, so it is the one place their commands and flags are set. Run it on the files you add or change as you go, and fix what it reports:

```bash
script/lint <files>
```

- A linter's config among the files runs that linter on everything, as CI does; `--all` runs them all, and `--only <linter>` just one. Run `npm ci` first if `node_modules` is missing, and install uv (https://docs.astral.sh/uv/) if `uvx` is
- The pre-commit hook (`.githooks/pre-commit`) runs `script/lint --staged`, on the staged version of each file, so another session's unstaged edits don't count. Git runs it once `core.hooksPath` is `.githooks` (`script/agent-env/install.sh` sets it; otherwise run `git config core.hooksPath .githooks` once). If it fails, fix the offenses and commit again. Never skip it with `--no-verify`
- Disable a check only where its rule genuinely doesn't apply, and say why (`test_every_disable_says_why`): `# rubocop:disable Dandelion/... -- reason`, `<%# erb_lint:disable DesignClasses: reason %>`, `// eslint-disable-next-line <rule> -- reason`, `/* stylelint-disable-line <rule> -- reason */` (or `<%# stylelint-disable-next-line <rule> -- reason %>` in a template), `# zizmor: ignore[<audit>] -- reason`, `# shellcheck disable=SC2086 # reason`, and for Herb the reason in an ERB comment on the line above. actionlint has no disable comments: add an `ignore` pattern to its config, saying why
- Scripts in templates share the page's globals, so a library or a function another file or template defines needs adding to `libraries` or `shared` in `eslint.config.mjs`
- A rule that code can check gets a check: a cop, linter or config rule, or a test in `test/lint_test.rb`, with cases there (each cop's `@example`, good and bad, is tested as it stands). It doesn't boot the app: `bundle exec ruby -I test test/lint_test.rb`

## Running the app

- Run `foreman run bundle exec rake db:seed` to seed the database
- Run `foreman start -e .env web` to start the web process (Puma on port 3000) if it is not already running. In a cloud environment it starts on boot (Cloud agents)
- Login with `SEED_ACCOUNT_EMAIL` and `SEED_ACCOUNT_PASSWORD` in `.env`

## MCP servers

- Project MCP servers come from the committed `.mcp.json`, which Claude Code reads, its `${VAR}`s filled from your shell. Other tools don't read it, so each has its own committed copy of the same servers, with secrets read from the environment rather than written in: `.cursor/mcp.json` (`${env:VAR}`), `.codex/config.toml` (`env_vars` and `bearer_token_env_var`; Codex only reads it in trusted projects) and `.opencode/opencode.json` (`{env:VAR}`). Only edit `.mcp.json`, then run `rake mcp:sync` to write the others. Variables in `.mcp.json` can't have defaults (`${VAR:-x}`), as the others can't express them
- MongoDB MCP: `.mcp.json` runs `mongodb-atlas-mcp-remote`, a proxy to the Atlas Managed MCP Server (`https://mcp.mongodb.com`), with read-only access to production. The server lists write tools (`insert-many`, `update-many`, `delete-many`, `drop-*`, `atlas-create-*`); never call them

## Mongo

- We set `Mongoid.raise_not_found_error = false` in `boot.rb` so `Model.find(id)` returns `nil` for invalid ids
- Nil booleans are converted to false using `after_initialize :convert_nil_booleans_to_false` and `before_validation :convert_nil_booleans_to_false`
- Mongo indexes are created directly in the database, and are not defined in model files (`Dandelion/MongoidIndex`)
- `Event.hinted(index_name)` makes MongoDB skip query planning, for queries it can't cache a plan for (e.g. an organisation's events `$or`, ~300 ms to plan: `events_including_cohosted.hinted(Event::HOSTS_INDEX)`). Hint only at call sites that need it, since it overrides more selective indexes. Index existence is checked once per process: dropping a hinted index needs a restart (or the queries fail), renaming one a code change
- Unique indexes:
  - Back every `validates_uniqueness_of` with a unique index
  - If nil is allowed, filter it with `partialFilterExpression: { field: { $type: '<BSON type>' } }`, never `$exists: true` (Mongoid stores explicit nulls, which would clash). If nil isn't allowed, use a plain unique index with no filter, but only if every document has the field: documents missing it count as nulls and would clash
  - Beside every `$type`-filtered index, keep a plain non-unique index on the same fields (e.g. `slug_1` beside `slug_1_unique`) unless another plain index starts with them: the planner can't use the filtered one for plain `{ field: x }` queries, including the validation's own. Never drop that plain index, and don't add a `$type` condition to the validation instead
  - Random values that can't clash, like UUIDs and other `SecureRandom` tokens (`token`, `ics_key`, `link_token`, `DragonflyJob#uid`), get a unique index but no `validates_uniqueness_of` or `exists?` loop, which would cost a query on every create. Short or derived values (`evm_secret`, `DragonflyJob#signature`) keep the validation
  - Check index use with the slow query log or `$indexStats` (0 ops means unused)

## Tracing

- Every request is traced, but `before_send_transaction` (`config/sentry_config.rb`) saves it to the `traces` collection (`Trace`) and returns nil: Sentry gets only errors and logs, never transactions or profiles. For performance data, query `traces` (e.g. with the MongoDB MCP), not Sentry: `name` (route), `duration_ms`, `http_status`, `release`, `started_at`
- Requests matching no route and `GET /health` aren't saved. Mongo queries become spans via `SentryMongoCommandSubscriber`, and outgoing HTTP requests (Stripe, Google...) `http.client` spans via Sentry's `:http` patch, with secret query values filtered and no trace headers sent
- Spans are zstd-compressed in `spans_zstd`, so Mongo queries can't read them; use `Trace#spans` in Ruby. Atlas Search pipelines and timings are also stored uncompressed in `search_spans`

## Tests

Choose how a test reaches the app by who is on the other end of the request:

- Nobody (permissions, pricing, validations, callbacks): call the models directly
- A program (webhooks, MCP, Zapier, JSON, ICS and CSV, status codes, redirects and headers): Rack (`Rack::Test::Methods`: `get`, `post`, `last_response`, `sign_in_with_rack`)
- Someone forging a request the UI can't make (another account's ids, `protected_attributes`, `$` operators, a route whose control is hidden from them): Rack
- A person (what they see, click and fill in, and what happens next): the browser (Capybara with Cuprite: `visit`, `click_on`, `sign_in`). Submit a form by filling it in, not by posting its params by hand in Rack, which keeps passing when the form's fields change
- A rule about what someone can't do gets both: a browser test that they aren't offered it, and a Rack test that the route refuses it anyway

A test uses one or the other (`Dandelion/TestOneParadigm`): they don't share a session. A file includes `Rack::Test::Methods` and `Capybara::DSL` only if its tests use them (`Dandelion/TestUnusedParadigm`). A program's request in the middle of a person's flow, like Stripe's webhook after a checkout, is the exception, with a disable saying so. Older Rack tests that check what a server-rendered page says can stay; write new ones of those in the browser.

Test files are in a folder per area (`test/events/hosts_test.rb`, `test/bookings/rules_test.rb`...), and a few that fit none are in `test/` itself. You can use the following command structure to test a single file, `$1` being its path in `test/` without `_test.rb` (e.g. `events/hosts`): `foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb`

To run only certain tests in a file, add `-n /pattern/` (matches the method name, with spaces as underscores) e.g. `foreman run -e .env.test bundle exec ruby -I test test/$1_test.rb -n /youtube_titles/`

Each test run gets its own database (`dandelion_test_<pid>`, dropped when the run ends) and a free port, set in `config/boot.rb`, so runs can go at the same time, in one checkout or several. To run several files at once, start each in its own process, e.g. `printf '%s\n' accounts/accounts events/events | xargs -P 2 -I{} sh -c 'mkdir -p tmp/$(dirname {}) && foreman run -e .env.test bundle exec ruby -I test test/{}_test.rb > tmp/{}.log 2>&1'`; each browser run starts its own Chrome, so keep to 3 or 4 at once. Test files take minutes, so if your tool can run commands in the background, start test runs there and keep working until they finish. Each run saves its screenshots to `capybara/<pid>/`, kept for an hour after the run ends.

CI runs the test files in groups, each group a job that runs its files in one process (`rake test:files`), listed in `.github/workflows/ruby.yml` by their path in `test/`: add a new test file to a group there. GitHub's Free plan runs 20 jobs at once across the organisation, and a push also starts the lint job, CodeQL and Sentry release, so there are at most 15 groups (`MAX_CI_TEST_GROUPS` in `test/lint_test.rb`) and they all start together. Put a new file in a group on the same subject, keeping each group under five minutes, as the slowest sets how long CI takes. A file that uploads images to ImageMagick goes in the group with `images`, the only one that installs it. In CI a failing test runs up to 3 times before it counts as failed (`TEST_ATTEMPTS` in `test/test_config.rb`), and one that passes on a later attempt gets a Flaky test warning on the run's summary; locally each test runs once. The file itself runs again only if it times out.

Coverage: CI measures, when run with coverage ticked (Run workflow on the Ruby workflow, or `gh workflow run Ruby -f coverage=true`), which lines of the app's Ruby and templates the tests run (SimpleCov, `test/test_coverage.rb`), and its coverage job puts the totals and least-covered files in the run's summary and the whole report in its `coverage` artifact. To see what a file of tests covers locally, run it with `COVERAGE=1` and open `coverage/index.html`; runs at the same time merge their results there. Lines a test runs aren't necessarily lines it checks, but lines none runs are untested: look there for what's missing tests.

Routes and tests: a test that's about a route starts with `covers_route 'VERB /path'` (one per route, the path as the controller writes it, e.g. `covers_route 'POST /orders/:id/transfer'`), beside any `covers`. `test/lint_test.rb` reads the routes from `app/app.rb` and `app/controllers` (`lib/route_marks.rb`) and fails on a route no test covers, unless `test/routes_without_tests.yml` says why, and on a `covers_route` naming no route. So a new route needs a test that covers it, or a reason there; once a test covers a route listed as Not tested yet, take it out of the list. The marks were first written from which routes each test requested (RECORD_ROUTES=1, or Run workflow on the Ruby workflow with record routes ticked), so some sit on a test that only requested the route on the way: move a mark to a better test when you write one.

Never attempt to run the full test suite. Your default posture should be to run only added/modified tests and any other clearly relevant tests, unless the change is substantial, in which case it may be appropriate to run whole files.

`@` instance variables come from helpers, and anything created inline in a test is a local (`Dandelion/TestInstanceVariable`). Use `create_event(as: :event1)` when a test needs more than one event.

Keep each test file to one subject, in its area's folder, splitting it when it grows past several hundred lines (e.g. `events/events`, `events/hosts`, `events/listings`): files in a CI group share one process, so more files cost nothing. Give each file a test class named for its area and subject (`EventHostsTest`): the files in a group load into one process, so two classes with the same name would merge. Helpers only one file uses are defined in it; helpers the files on a subject share go in a module in `test/helpers`, named for what it holds (e.g. `BookingsHelpers` in `bookings_helpers.rb`), which each file requires and includes. Helpers every test needs are in `TestHelpers` (`test/helpers/test_helpers.rb`), which every test includes; `test/test_config.rb` is only setup: boot, Capybara, the test database and how each test runs.

Straight after a click or submit, assert something on the new page before checking something isn't there, or that check can pass on the old page (`Dandelion/CapybaraHasNoAfterClick`; and check with `assert page.has_no_*`, as `Dandelion/CapybaraRefuteHas` says).

## Conventions

- Controllers are `Dandelion::App.controller` blocks with `erb` / `partial` / `cp` (`Dandelion/RailsController` checks for Rails habits)
- URLs name organisations, gatherings, events, activities, local groups and accounts by slug, never by id: find them with `organisation_from_params`, `event_from_params` (`event_from_params(Event.unscoped)` to include deleted events), `gathering_from_params`, `activity_from_params`, `local_group_from_params` and `account_from_params`, which 404 when there is none, so need no `|| not_found`, or with `find_by_slug_or_id` (`Dandelion/SlugLookup`). Ids from forms and query strings are fine, and a route for an old URL that named one by id redirects with `redirect_to_slug_url`
- Gathering routes (`/g/:slug/...`): find the gathering with `gathering_from_params` and its records through it (`@gathering.shifts.find(...)`, `Dandelion/GatheringScope`), and say who may use the route (`Dandelion/GatheringPermission`): `confirmed_membership_required!` or `membership_required!` (which set `@membership`), `gathering_admins_only!`, `own_or_gathering_admins_only!(record)` for someone's own shift, teamship or optionship, or `halt 403`
- Files in lib are auto-loaded by Padrino.load!. No explicit require is necessary.
- Emails go through `Mailer.deliver` (`lib/mail/mailer.rb`): a template in `app/views/emails` (or `content:`, `html:`, `text:`), `to:` accounts (each gets `Account#mail_variables`) or `[email, variables]` pairs, and `stream:`, `via:` an organisation, `attachments:`. It picks the Mailgun domain and sender, sends only in production, and builds the `Mailgun::BatchMessage` that `EmailHelper::RecipientVariables` makes safe and tests record (`recorded_email`). Don't build a Mailgun message yourself (`Dandelion/MailgunDirect`)
- Prefer helpers, models and concerns to `lib`: code only controllers and views call goes in a helper, and code about a model on the model or in a concern (`models/concerns`, as `AppModels.all` takes every file in `models` itself for a model). `lib` is for what fits neither: framework glue and patches, API clients, service objects, and code that models, tasks or boot share with helpers
- `lib/form_builder.rb` defines the `_block` helpers like `text_block`, `wysiwyg_block` etc.
- You can find documentation at app/views/docs/md. Keep it up to date.

## Docs and tests

What the docs (`app/views/docs/md`) say the app does is checked by tests, through claims (`lib/doc_claims.rb`):

- Mark a rule the docs state with `<!-- claim: some-id -->` straight after it. The claim is the text before the marker, back to the start of its line (after any list bullet or quote marker) or the marker before it, so put untested sentences after the last marker on a line, not between two. Markers come out before the docs render. Mark rules about what happens (a refund, an email, which ticket goes first), not how to click through the UI
- A test that checks a claim starts with `covers 'page/some-id@hash'` (one or more), the hash being of the claim's text. `test/lint_test.rb` fails when a claim has no test, a test covers a claim that's gone, or a claim's text has changed since its tests were checked against it: then read the new text, make sure each test still tests it (or change the test), and update the hash the message gives
- When you add or change what the docs say, mark the rules it states and cover them

## Security reviews

- Every model runs `sanitize_fields` (`models/concerns/core_extensions.rb`) before validation: it strips tags and drops `<` and `>` from `name`, `title` and `subject` (`CoreExtensions::SANITIZED_FIELDS`). So a view or helper that outputs one of these unescaped (e.g. `dropdown_nav`, `ul_nav`, `"#{x.name}".html_safe`, Tribute's mention menu) is not an XSS on its own. Before reporting one, show a write path that skips validation (`set`, `update_one`, `save(validate: false)`) or a field outside that list, and check whether a form can set the field at all (`mass_assigning`, below)
- `mass_assigning` (`app/helpers/helpers.rb`) decides which keys a form can set in two steps:
  - By kind of setter, it's an allowlist: only the model's `form_attributes` (`models/concerns/core_extensions.rb`) get through. These are its own fields, less ids, timestamps, foreign keys and attachment storage fields (`image_uid` etc.), plus what the model lists: `assignable_foreign_keys`, attachments and `remove_<attachment>`, nested attributes (each nested record is filtered the same way with its own model) and `virtual_attributes` (setters that aren't fields, like TicketType's `price_or_range`). Everything else is dropped: every other setter Mongoid or Dragonfly generates, like has_many `<name>_ids=` (which re-parents the given records) or `retained_<attachment>=`, and any `attr_accessor` not in `virtual_attributes`
  - By field, it's still a denylist: a form can set any of the model's own fields unless it's in `protected_attributes`, which raise. So a new field that forms mustn't set (a cache, a flag only admins or code set) needs adding to `protected_attributes`. List only fields there: keys `form_attributes` already leaves out don't need it (a test in `test/events/permissions_test.rb` checks this)
  - A model that lists `permitted_attributes` (Account, EventBoost) uses that list instead of `form_attributes`, so it's an allowlist by field too; Account's includes the `attr_accessor`s `postcode` and `country`
- `<%= %>` escapes by default (Padrino `SafeErubi`); look at `<%==`, `.html_safe` and `raw` for XSS
- Uploads reach ImageMagick (through Dragonfly) only once `ImageSignature` has seen JPEG, PNG, GIF, WebP or HEIC bytes, and `config/dragonfly_config.rb` loads `config/imagemagick/policy.xml`, which denies SVG, MSL, TEXT, URL fetches and Ghostscript. Render's image ships no policy of its own. Anything new that hands a user's file to ImageMagick needs the same check first
- `app/helpers/param_helpers.rb` strips Mongo `$` operators from form params (not from JSON request bodies)

## Build/vendored code

- CKEditor is our own build in `ckeditor/`, on CKEditor 37.1.0: 38 and later show a Powered by CKEditor badge under the GPL. Never edit `app/assets/javascripts/ext/ckeditor.js`: change `ckeditor/src/ckeditor.js` and run `rake ckeditor:build` (needs Node)
- Never edit `bootstrap5.css` (compiled vendor CSS): change Bootstrap's variables in `bootstrap5.scss` and run `rake bootstrap:build` (needs Node)
- jQuery UI is built from just the modules we use, not loaded whole from the CDN: `ext/jquery-ui-autocomplete.min.js` on every page (the header search, messages search and location fields) and `ext/jquery-ui-interactions.min.js` (sortable, draggable, droppable) on the pages that drag things, which load it with `<script ... defer>` after the first. Its theme CSS isn't loaded: the few rules the autocomplete needs are in `app.css`. Never edit the built files: change the modules or the version in `tasks/build.rake` and run `rake jquery_ui:build` (needs Node). A widget not in them (`datepicker`, `dialog`, `tooltip`...) isn't loaded

## Design

The design guide (`/design`, `app/views/design.erb`) shows the colours, type, spacing, components and their classes. Check it before styling anything, and keep it up to date when you change them. The rules it doesn't spell out are below, apart from those with a check (showing and hiding, success and badge classes, colours, spacing), which the linters check:

- Stylesheets are plain CSS. Override Bootstrap in `app.css` (see Build/vendored code for changing its variables). Page-specific styles go in their own file loaded only by those pages (e.g. `docs.css`, `messages.css`)
- Bootstrap 5 with jQuery: `mb-3` between fields (its `data-bs-*` attributes, logical spacing and `form-select` are checked by erb_lint)
- Filter forms above lists and tables use `.form-inline` and `.form-group` (kept in `app.css`) inside `.searchForm`; add `.submitOnChange` to submit when a field changes. Date fields take `.datepicker` or `.datetimepicker`, which `forms.js` wires up
- Tooltips are `data-bs-toggle="tooltip"` and a `title`; `app.js` handles them for the whole page, so content loaded later needs no setup
- Motion: shows where things come from and go, and is otherwise kept out of the way. State changes fade over `--transition-fast`; things that float (dropdown menus, the confirm popover, flash toasts) fade in over `--transition-enter`, moving at most `--space-2xs`; modals keep Bootstrap's slide; chevrons on things that open in place turn. Nothing bounces or reveals on scroll; what transitions may animate, their durations and looping are checked by Stylelint
- Avatars: `partial :'accounts/square', locals: { account:, size: :xs }` (`:xs` to `:2xl`, default `:sm`, or `:fill`). For a bare `<img>` of an account, use `class="avatar avatar-sm"` rather than a width

## Dependencies

Cooldown: never use a gem or JS package version released less than 7 days ago. This guards against supply-chain attacks on freshly published versions. If a version that was just released can't be found, that's why: wait until it's a week old rather than removing or shortening the cooldown.

Each night `.github/workflows/package-updates.yml` runs `script/update_packages.rb`, which updates the gems, frontend packages and actions `/stats/packages` lists to their newest releases out of the cooldown, and opens (or refreshes) a pull request from the `package-updates` branch. To keep a package on a major version, add it to `HOLD` in the script (or give a gem a constraint in the Gemfile).

- Gems: the Gemfile's source has `cooldown: 7`, so Bundler enforces it
- GitHub Actions are pinned to a commit of a release at least 7 days old, with the release as a comment (zizmor's `unpinned-uses`), but for ruby/setup-ruby when the Gemfile's Ruby is newer than that release knows: then it's the first release that knows it. zizmor's, actionlint's and ShellCheck's own versions are in `script/lint`, and uv's in `.github/workflows/ruby.yml` and `script/agent-env/install.sh`
- `rake bootstrap:build` runs `npm install` with `--before` set to 7 days ago
- The root `package.json` is only linters (Linting): ESLint, Stylelint, the PostCSS parser Stylelint reads templates with, and Herb's linter. It installs from `package-lock.json` (`npm ci`): pin exact versions, and when adding or bumping one run `npm install --before=<the date a week ago>` so its own dependencies are a week old too
- `ckeditor/` installs from its `yarn.lock`. Yarn 1 has no cooldown, so when refreshing the lockfile (`yarn upgrade`), check the new versions' release dates (`npm view <package> time`) and pin back any that are under a week old
- The packages the app loads from jsDelivr have their versions in `frontend/package.json`, and only there: nothing installs them, `config/frontend_dependencies.rb` reads them. `FRONTEND_DEPENDENCIES` there lists the packages every page loads and their files; a page that needs one of its own loads it with `cdn_tag`. Like gems, they're bumped by hand (`/stats/packages` lists what's outdated, for both), and GitHub's security alerts read the same file. When adding or bumping a package, or a version in a rake task, pick a version at least 7 days old (`rake frontend:integrity` refuses a newer one)
- iframe-resizer stays on 4 (4.4.5 is MIT): 5 and later are GPL-3.0, or a paid licence. The embed code in `app/views/docs/md/events.md` loads its parent script at the same version
- CDN files load with `cdn_tag` (`CdnTags`), whose `integrity` attribute makes the browser refuse a file that's changed since we chose it. After adding or bumping one (CI's lint job fails until you do), run `rake frontend:integrity`, which hashes each CDN file that has no hash yet into `frontend/integrity.json` and drops those nothing loads any more. It keeps the hashes it has rather than trusting the CDN again, and refuses to hash a version of an npm package released less than 7 days ago (the cooldown), as a hash pins whatever the version is. Load a file the package ships: jsDelivr minifies a `.min` file a package lacks on the fly, and the task refuses one, as that output can change

Before adding a gem or a frontend package, check whether one we already have does the job: `Gemfile`, `frontend/package.json`.

## Cloud agents (Cursor, Claude Code on the web)

What differs in a cloud agent's environment.

Shared setup lives in `script/agent-env/`: `system-deps.sh` (apt packages, Chromium, MongoDB), `ruby.sh` (the Gemfile's Ruby, for images without it), `node.sh` (the Node in `.nvmrc`, which CI's setup-node also reads, for images without its major; installed at a prefix of its own rather than over the image's Node), `browser-path.sh` (prints the Chromium for `BROWSER_PATH`), `install.sh` (bundle install, npm ci for the linters and uv for zizmor, actionlint and ShellCheck, which only warn if they fail, `.env` files, the pre-commit hook), `start-services.sh` (starts MongoDB) and `start-web.sh` (starts Puma in the background, logging to `log/web.log`, for environments with no terminal to keep it in). A tool's own setup only calls these, plus anything that applies to that tool alone (Claude Code's proxy CA and `CLAUDE_ENV_FILE`).

- Cursor: `.cursor/environment.json` and `.cursor/Dockerfile`. After boot, `start` forks Mongo; a `web` terminal keeps `foreman start -e .env web` running (Puma on port 3000, logs in that session). That terminal is a tmux session, so the Dockerfile installs tmux
- Claude Code on the web: a `SessionStart` hook in `.claude/settings.json` runs `.claude/remote-setup.sh`
- The web process: both cloud agents start it on boot: Cursor in its `web` terminal, and Claude Code on the web in the background (`script/agent-env/start-web.sh`) with logs in `log/web.log`. Puma takes about 20 seconds to boot, so if port 3000 isn't answering yet, check the log or wait rather than starting a second copy
- MCP servers: Claude Code on the web fills `.mcp.json`'s `${VAR}`s from the cloud environment's variables. Cursor cloud agents don't read any repo MCP file; their MCP servers are set up in the Cursor dashboard
- Browsing the app with Playwright (Claude Code on the web): Chromium ignores `HTTPS_PROXY`, so pass it or CDN assets (jQuery etc.) won't load and nothing works: `chromium.launch({ executablePath: process.env.BROWSER_PATH, args: ['--proxy-server=' + process.env.HTTPS_PROXY] })`. Don't use Playwright's `proxy` option: it sends localhost through the proxy too, which rejects it. The setup script trusts the proxy's CA in Chromium's NSS store (`~/.pki/nssdb`); never ignore certificate errors instead. Cuprite gets the proxy from `test/test_config.rb`
