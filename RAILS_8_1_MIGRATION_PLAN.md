# Rails 8.1 Migration Plan for Dandelion

## Executive Summary

This plan outlines migrating the Dandelion Padrino/Sinatra application to Rails 8.1 while **minimizing code changes**. The strategy preserves:
- **MongoDB/Mongoid database layer** (no migration to SQL needed)
- **Exact Sinatra-style controller syntax** (`get '/path' do ... end`) - **ZERO logic changes**
- Existing view templates (ERB)
- Model architecture with concerns (100% unchanged)
- Helper organization

**Migration Approach:** Keep Sinatra gem for DSL compatibility. Controllers simply wrap existing `get/post` blocks in a Rails class.

**Estimated Total Code Changes:** ~1,800 lines (mostly new Rails configuration)
**Actual Logic Changes:** ~700 lines (wrapper code only)

**Files Requiring Modification:** ~50-70 files (mechanical changes only)
**Files Remaining Unchanged:** ~550+ files (85 models, 482 views, ALL controller logic)

---

## Table of Contents

1. [Current Architecture Summary](#1-current-architecture-summary)
2. [Rails 8.1 Compatibility Strategy](#2-rails-81-compatibility-strategy)
3. [Migration Phases](#3-migration-phases)
4. [Detailed Migration Steps](#4-detailed-migration-steps)
5. [Gem Migration Map](#5-gem-migration-map)
6. [File-by-File Changes](#6-file-by-file-changes)
7. [Testing Strategy](#7-testing-strategy)
8. [Rollback Plan](#8-rollback-plan)
9. [Post-Migration Optimization](#9-post-migration-optimization)

---

## 1. Current Architecture Summary

### Application Stats
- **Framework:** Padrino 0.15.x (Sinatra-based)
- **Database:** MongoDB via Mongoid 8.x
- **Models:** 85 models (~7,048 LOC) + 44 concerns (~4,397 LOC)
- **Controllers:** 49 controllers (~6,623 LOC) in Sinatra-style
- **Views:** 482 ERB templates
- **Ruby Version:** 3.4.7

### Key Dependencies
- `padrino` → Replace with `rails`
- `sinatra` → Absorb into Rails routing
- `mongoid` → **Keep** (Rails-compatible)
- `activate-admin` → **Keep** (mount as Rails engine)
- `dragonfly` → Evaluate migration to ActiveStorage
- All other gems → Mostly compatible with Rails

---

## 2. Rails 8.1 Compatibility Strategy

### Core Principle: Minimal Disruption

Rails 8.1 can accommodate **all** of your existing patterns by keeping Sinatra compatibility:

1. **Sinatra-style Routes:** Keep EXACT syntax (`get '/path' do ... end`) using Sinatra DSL
2. **Mongoid:** Fully compatible with Rails 8.1
3. **ERB Templates:** 100% compatible
4. **Helpers:** Convert to Rails helpers (minor syntax changes)
5. **Middleware:** Rails Rack middleware stack works identically

### What Changes vs. What Stays

| Component | Change Level | Strategy |
|-----------|-------------|----------|
| Models (85 files) | **None** | Zero changes - Mongoid works identically |
| Controllers (49 files) | **Minimal** | Keep `get/post` syntax, just wrap in Rails controller class |
| Views (482 files) | **Minimal** | Update helper calls, keep templates |
| Helpers (7 files) | **Light** | Convert to Rails helper modules |
| Routes | **New** | Auto-generate from controllers or create thin mapping |
| Config | **New** | Rails standard config structure |
| Gemfile | **Light** | Keep Sinatra alongside Rails for DSL compatibility |

---

## 3. Migration Phases

### Phase 1: Preparation (No Code Changes)
- Audit all routes and create route inventory
- Document all middleware and before filters
- Identify gem compatibility issues
- Set up parallel Rails 8.1 branch

### Phase 2: Rails Setup
- Generate new Rails 8.1 app with `--skip-active-record` flag
- Configure Mongoid for Rails
- Set up Mongoid models inheritance
- Migrate configuration files

### Phase 3: Core Migration
- Wrap controllers in Rails classes (keep Sinatra DSL - no logic changes!)
- Update helpers
- Create routes.rb mapping
- Note: Models need ZERO changes!

### Phase 4: Dependencies
- Migrate authentication (OmniAuth)
- Migrate file uploads (Dragonfly → ActiveStorage or keep Dragonfly)
- Migrate admin interface (ActivateAdmin)
- Update middleware stack

### Phase 5: Testing & Validation
- Run existing test suite
- Fix breaking changes
- Validate all routes work
- Test background jobs

### Phase 6: Deployment
- Deploy to staging
- Smoke test all features
- Deploy to production

---

## 4. Detailed Migration Steps

### Step 1: Generate Rails App (Skip ActiveRecord)

```bash
# Create new Rails 8.1 app without ActiveRecord
rails new . --skip-active-record --skip-spring --skip-test --skip-jbuilder --skip-turbo

# This preserves your existing directory structure
# Rails will add its standard directories alongside existing ones
```

**Changes this creates:**
- `config/application.rb`
- `config/environment.rb`
- `config/environments/*.rb`
- `config/initializers/`
- `bin/` directory with Rails executables

### Step 2: Configure Mongoid for Rails

**config/application.rb:**
```ruby
require_relative "boot"
require "rails"

# Require only the frameworks you need
%w(
  active_model/railtie
  active_job/railtie
  action_controller/railtie
  action_view/railtie
  action_mailer/railtie
  active_storage/engine  # If using ActiveStorage
  action_cable/engine
  rails/test_unit/railtie
).each do |railtie|
  require railtie
end

# Require mongoid instead of activerecord
require "mongoid/railtie"

Bundler.require(*Rails.groups)

module Dandelion
  class Application < Rails::Application
    config.load_defaults 8.1
    config.generators { |g| g.orm :mongoid }
  end
end
```

**Keep existing:** `config/mongoid.yml` (no changes needed!)

### Step 3: Update Gemfile

**Replace:**
```ruby
gem 'padrino'
```

**With:**
```ruby
gem 'rails', '~> 8.1.0'
```

**Keep:**
```ruby
gem 'sinatra', require: false  # Keep for DSL compatibility!
```

**Keep all other gems:**
- `mongoid` ✓ Rails-compatible
- `mongoid_paranoia` ✓ Works with Rails
- `delayed_job_mongoid` ✓ Works with Rails
- `dragonfly` ✓ Works with Rails (or migrate to ActiveStorage)
- `omniauth` ✓ Rails has built-in support
- `activate-admin` ✓ Mount as Rails engine
- All payment, mail, and utility gems ✓ Unchanged

**Update:**
```ruby
# Remove (Rails includes these)
# gem 'activesupport'

# Update testing
group :test do
  gem 'capybara'
  gem 'cuprite'
  gem 'minitest' # Rails includes this
end
```

### Step 4: Create Application Controller Base

**app/controllers/application_controller.rb:**
```ruby
class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception, unless: -> { request.format.json? }

  # Import all helper modules
  helper :all

  # Port over before filters from app/app.rb
  before_action :set_time_zone
  before_action :detect_crawler
  before_action :load_context

  # Port over helper methods from app/helpers/helpers.rb
  include AccountsHelper
  include SignInHelper
  include AccessControlHelper
  include SearchHelper

  # Methods that were in Padrino::Helpers
  def current_account
    @current_account ||= Account.find(session[:account_id]) if session[:account_id]
  rescue Mongoid::Errors::DocumentNotFound
    session.delete(:account_id)
    nil
  end

  def mass_assigning(hash, model)
    # Port logic from helpers.rb
    # ... existing implementation
  end

  # ... port other helper methods

  private

  def set_time_zone
    # Port from app/app.rb before filter
  end

  def detect_crawler
    # Port crawler detection
  end

  def load_context
    # Port context loading (org, activity, local_group)
  end
end
```

### Step 5: Keep Controllers (EXACT Sinatra Syntax)

**Strategy:** Keep your existing `get/post` syntax by using Sinatra DSL within Rails controllers.

**Option A: Use sinatra-rails gem (Recommended)**

Add to Gemfile:
```ruby
gem 'sinatra', require: false
```

**Example: app/controllers/events.rb (Minimal Changes):**

**Before (Padrino):**
```ruby
Dandelion::App.controller do
  get '/events', provides: %i[html ics json] do
    @events = Event.live.public.browsable
    # ... your existing code
  end

  post '/events/new' do
    @event = Event.new(mass_assigning(params[:event], Event))
    # ... your existing code
  end
end
```

**After (Rails with Sinatra DSL):**
```ruby
class EventsController < ApplicationController
  include Sinatra::DSL

  # EXACT SAME SYNTAX - Zero changes to route handlers!
  get '/events', provides: %i[html ics json] do
    @events = Event.live.public.browsable
    # ... EXACT SAME CODE
  end

  post '/events/new' do
    @event = Event.new(mass_assigning(params[:event], Event))
    # ... EXACT SAME CODE
  end
end
```

**Changes Required:**
1. Wrap in `class XController < ApplicationController`
2. Add `include Sinatra::DSL`
3. **Everything else stays IDENTICAL!**

**Option B: Custom DSL Module (No Sinatra Dependency)**

Create a compatibility module:

**lib/sinatra_compat.rb:**
```ruby
module SinatraCompat
  extend ActiveSupport::Concern

  class_methods do
    def get(path, options = {}, &block)
      action_name = "get_#{path.gsub('/', '_').gsub(':', '')}"
      define_method(action_name, &block)

      # Auto-register route in Rails
      Rails.application.routes.draw do
        get path, to: "#{controller_name}##{action_name}", **options
      end
    end

    def post(path, options = {}, &block)
      action_name = "post_#{path.gsub('/', '_').gsub(':', '')}"
      define_method(action_name, &block)

      Rails.application.routes.draw do
        post path, to: "#{controller_name}##{action_name}", **options
      end
    end

    # Similar for put, patch, delete...
  end
end
```

**Then in controllers:**
```ruby
class EventsController < ApplicationController
  include SinatraCompat

  # EXACT SAME SYNTAX!
  get '/events', provides: %i[html ics json] do
    @events = Event.live.public.browsable
    # ... your code
  end

  post '/events/new' do
    # ... your code
  end
end
```

**Key Point:** With either approach, your controller logic stays **100% unchanged**. Only the wrapper class changes.

### Step 6: Routes (Auto-generated or Manual)

**Option A: Auto-generated from Controllers (If using SinatraCompat)**

With Option B (custom DSL), routes auto-register themselves. Your `config/routes.rb` only needs:

```ruby
Rails.application.routes.draw do
  # Mount admin interface
  mount ActivateAdmin::Engine, at: '/dadmin'

  # All other routes auto-registered by controllers!
  # Just load all controllers
  Dir[Rails.root.join('app/controllers/**/*_controller.rb')].each { |f| require f }
end
```

**Option B: Manual Routes (If using Sinatra gem directly)**

If using `include Sinatra::DSL`, you still need to map routes manually:

```ruby
Rails.application.routes.draw do
  # Mount admin interface
  mount ActivateAdmin::Engine, at: '/dadmin'

  # Mount each controller's routes
  # Rails will delegate to Sinatra DSL within each controller

  # Events (handled by EventsController Sinatra DSL)
  mount EventsController, at: '/'

  # Organisations
  mount OrganisationsController, at: '/'

  # ... mount other controllers

  # Or use constraint routing
  get '*path', to: proc { |env|
    # Dispatch to appropriate controller based on path
    # Controllers handle routing via Sinatra DSL
  }
end
```

**Option C: Explicit Rails Routes (Most Compatible)**

Map all routes explicitly (but controllers still use Sinatra syntax):

```ruby
Rails.application.routes.draw do
  # Mount admin interface
  mount ActivateAdmin::Engine, at: '/dadmin'

  # Events - EventsController uses Sinatra DSL internally
  get '/events', to: 'events#get_events', as: 'events'
  post '/events/new', to: 'events#post_events_new'
  get '/e/:id', to: 'events#get_e_id', as: 'event'

  # Organisations
  get '/organisations', to: 'organisations#get_organisations', as: 'organisations'

  # ... explicit mapping for each route
end
```

**Recommended:** Use **Option C** for maximum clarity and Rails compatibility while keeping Sinatra syntax in controllers.

### Step 7: Migrate Models (Minimal Changes)

Models need almost no changes! Just update includes.

**Current model pattern:**
```ruby
class Event
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  extend Dragonfly::Model
  include Mongoid::Paranoia

  include EventFields
  include EventAssociations
  # ... other concerns
end
```

**Rails version (almost identical):**
```ruby
class Event
  include Mongoid::Document
  include Mongoid::Timestamps
  include CoreExtensions
  extend Dragonfly::Model
  include Mongoid::Paranoia

  include EventFields
  include EventAssociations
  # ... other concerns

  # Optional: for Rails compatibility
  include ActiveModel::Validations
  include ActiveModel::Conversion
  extend ActiveModel::Naming
end
```

**Changes needed:**
- None for most models! Mongoid works identically in Rails
- Optionally add `app/models/concerns/` for concerns (or keep in `models/concerns/`)
- Keep all validation, association, scope, and callback logic unchanged

### Step 8: Migrate Helpers

Helpers convert easily to Rails helper modules.

**app/helpers/application_helper.rb:**
```ruby
module ApplicationHelper
  # Port all methods from app/helpers/helpers.rb

  def mass_assigning(hash, model)
    # ... existing implementation
  end

  def current_account
    @current_account ||= Account.find(session[:account_id]) if session[:account_id]
  rescue Mongoid::Errors::DocumentNotFound
    session.delete(:account_id)
    nil
  end

  def money_symbol(currency)
    # ... existing implementation
  end

  # ... all other helpers
end
```

**Domain-specific helpers:**
```ruby
# app/helpers/accounts_helper.rb
module AccountsHelper
  # Port from app/helpers/accounts_helper.rb
end

# app/helpers/events_helper.rb
module EventsHelper
  # Create new helper for event-specific methods
end
```

### Step 9: Configure Middleware Stack

**config/application.rb:**
```ruby
module Dandelion
  class Application < Rails::Application
    # ... other config

    # Port middleware from app/app.rb
    config.middleware.use Rack::UTF8Sanitizer
    config.middleware.use Rack::CrawlerDetect
    config.middleware.use Rack::Attack
    config.middleware.use Rack::Cors do
      allow do
        origins '*'
        resource '*', headers: :any, methods: [:get, :options]
      end
    end

    # Dragonfly
    config.middleware.use Dragonfly::Middleware

    # OmniAuth (or use initializer)
    config.middleware.use OmniAuth::Builder do
      provider :google_oauth2, ENV['GOOGLE_OAUTH2_KEY'], ENV['GOOGLE_OAUTH2_SECRET']
      provider :ethereum
      # ... other providers
    end
  end
end
```

### Step 10: Configure Asset Pipeline

Rails 8.1 uses Propshaft by default, but you can keep your existing asset setup.

**Option A: Keep existing (no asset pipeline):**
```ruby
# config/application.rb
config.assets.enabled = false

# Serve assets from public/ as before
# Keep existing Sass::Plugin::Rack middleware
```

**Option B: Use Propshaft (recommended):**
```ruby
# config/application.rb
config.assets.css_compressor = nil
config.assets.js_compressor = nil

# Move app/assets/* to app/assets/
# Precompile: rails assets:precompile
```

**Option C: Use cssbundling-rails + jsbundling-rails:**
```ruby
# Gemfile
gem "cssbundling-rails"
gem "jsbundling-rails"

# Keep existing frontend dependencies, just bundle differently
```

For minimal changes, **recommend Option A** initially.

### Step 11: Migrate Authentication (OmniAuth)

Rails has excellent OmniAuth support.

**config/initializers/omniauth.rb:**
```ruby
Rails.application.config.middleware.use OmniAuth::Builder do
  provider :google_oauth2,
    ENV['GOOGLE_OAUTH2_KEY'],
    ENV['GOOGLE_OAUTH2_SECRET'],
    {
      scope: 'email,profile',
      prompt: 'select_account',
      image_aspect_ratio: 'square',
      image_size: 500
    }

  provider :ethereum
end

OmniAuth.config.on_failure = Proc.new do |env|
  OmniAuth::FailureEndpoint.new(env).redirect_to_failure
end
```

**Authentication controller:**
```ruby
class AuthController < ApplicationController
  skip_before_action :verify_authenticity_token, only: [:omniauth_callback]

  def omniauth_callback
    # Port logic from app/controllers/auth.rb
    auth = request.env['omniauth.auth']
    # ... existing logic
  end
end
```

### Step 12: Migrate Background Jobs

Delayed Job works identically with Rails.

**config/initializers/delayed_job.rb:**
```ruby
Delayed::Worker.destroy_failed_jobs = false
Delayed::Worker.max_attempts = 3
Delayed::Worker.max_run_time = 5.minutes
Delayed::Worker.delay_jobs = !Rails.env.test?
```

**No changes to job code:**
```ruby
# Still works
@event.delay.send_reminder_emails
Delayed::Job.enqueue(SomeJob.new)
```

### Step 13: Migrate Rake Tasks

Move tasks from `tasks/*.rake` to `lib/tasks/*.rake`.

**No code changes needed!** Rails auto-loads rake files from `lib/tasks/`.

```bash
# Just move files
mkdir -p lib/tasks
mv tasks/*.rake lib/tasks/
```

### Step 14: Update View Templates

Views need minimal updates.

**Changes needed:**
1. Update asset paths: `/stylesheets/app.css` → `stylesheet_link_tag 'app'` (if using asset pipeline)
2. Update route helpers: `"/events"` → `events_path`
3. Keep everything else identical!

**Most views stay 100% unchanged** if you keep manual asset loading.

### Step 15: Configure Initializers

Create initializers for external services (port from `config/boot.rb`).

**config/initializers/dragonfly.rb:**
```ruby
# Port Dragonfly config from config/boot.rb
require 'dragonfly'
require 'dragonfly/s3_data_store'

Dragonfly.app.configure do
  plugin :imagemagick
  secret ENV['DRAGONFLY_SECRET']

  datastore :s3,
    bucket_name: ENV['S3_BUCKET_NAME'],
    access_key_id: ENV['S3_ACCESS_KEY'],
    secret_access_key: ENV['S3_SECRET']
end
```

**config/initializers/geocoder.rb**, **stripe.rb**, **openai.rb**, etc.
- Move all service configs from `config/boot.rb` to individual initializers
- No logic changes, just organization

### Step 16: Update Tests

Tests need minimal updates.

**test/test_helper.rb:**
```ruby
ENV['RAILS_ENV'] ||= 'test'
require_relative '../config/environment'
require 'rails/test_help'
require 'capybara/cuprite'
require 'factory_bot'

class ActiveSupport::TestCase
  include FactoryBot::Syntax::Methods

  # Port test helpers from existing test_config.rb
end

class ActionDispatch::IntegrationTest
  include Capybara::DSL

  # Capybara setup
  Capybara.default_driver = :cuprite
end
```

**Individual test files:** Update route references only.
```ruby
# Before (Padrino)
get '/events'

# After (Rails)
get events_path

# Or still works:
get '/events'
```

---

## 5. Gem Migration Map

| Current Gem | Rails 8.1 Strategy | Changes Needed |
|-------------|-------------------|----------------|
| `padrino` | **Remove** → `rails` | Config only |
| `sinatra` | **Keep** (for DSL syntax in controllers) | None |
| `mongoid` | **Keep** | None |
| `mongoid_paranoia` | **Keep** | None |
| `delayed_job_mongoid` | **Keep** or switch to `solid_queue` | None if keeping |
| `dragonfly` | **Keep** or → `active_storage` | None if keeping |
| `activate-admin` | **Keep** (mount as engine) | Update mounting |
| `omniauth-*` | **Keep** | Move to initializer |
| `will_paginate` | **Keep** or → `kaminari`/`pagy` | None if keeping |
| `bcrypt` | **Keep** (or use `has_secure_password`) | None |
| `stripe`, `gocardless_pro`, etc. | **Keep** | None |
| `mailgun-ruby` | **Keep** or use `action_mailer` | Config changes only |
| `rack-attack`, `rack-cors` | **Keep** | Move to config |
| All other gems | **Keep** | None |

**Gems to Remove:**
- `padrino`
- `activesupport` (Rails includes it)

**Gems to Keep (Important!):**
- `sinatra` - For maintaining `get/post` DSL syntax in controllers

**Gems to Add:**
- `rails` ~> 8.1.0

**Total Gemfile changes:** ~3 lines

---

## 6. File-by-File Changes

### New Files to Create (~15 files)

**Rails configuration:**
- `config/application.rb` (200 lines)
- `config/environment.rb` (5 lines)
- `config/environments/development.rb` (50 lines)
- `config/environments/production.rb` (80 lines)
- `config/environments/test.rb` (50 lines)
- `config/routes.rb` (500-800 lines - **largest new file**)

**Initializers (~10 files):**
- `config/initializers/dragonfly.rb`
- `config/initializers/geocoder.rb`
- `config/initializers/stripe.rb`
- `config/initializers/omniauth.rb`
- `config/initializers/delayed_job.rb`
- `config/initializers/cors.rb`
- `config/initializers/session_store.rb`
- `config/initializers/assets.rb` (if using asset pipeline)
- `config/initializers/mongoid.rb`
- ... others as needed

**Rails executables:**
- `bin/rails`
- `bin/rake`

### Files to Modify (~55 files)

**Controllers (49 files) - MINIMAL CHANGES:**
- Rename: `app/controllers/*.rb` → `app/controllers/*_controller.rb`
- Replace: `Dandelion::App.controller do` → `class XController < ApplicationController`
- Add: `include Sinatra::DSL` at top of class
- Replace: `end` (at bottom) → `end`
- **Keep ALL `get/post` blocks EXACTLY as-is!**
- No changes to route handler logic

**Helpers (7 files):**
- Wrap in `module XHelper` if not already
- Move to `app/helpers/*_helper.rb`
- Update any Padrino-specific helper calls

**Application entry:**
- `config.ru` - Update to `require_relative 'config/environment'; run Rails.application`

**Gemfile:**
- Remove `padrino`, `sinatra`
- Add `rails`
- Update as per migration map

**Procfile:**
- Update: `web: bundle exec puma -C config/puma.rb` → `web: bundle exec rails server`
- Keep: `worker: bundle exec rake jobs:work`

### Files Requiring No Changes (~540+ files)

**Models (85 files + 44 concerns):** Zero changes needed!
- Mongoid works identically in Rails
- All validations, associations, scopes, callbacks unchanged

**Views (482 files):** Minimal changes
- Keep all template logic
- Only update if using asset pipeline helpers
- Update route helpers (optional - can keep string paths)

**Lib files (25 files):** Zero changes
- All utility code works identically

**Rake tasks (files in tasks/):** Zero logic changes
- Just move to `lib/tasks/`

**Tests (18 files):** Minimal changes
- Update test helper setup
- Update route references to use path helpers (optional)

---

## 7. Testing Strategy

### Phase 1: Unit Tests (Models)
```bash
# Models should pass immediately (no changes)
rails test test/models/
```

### Phase 2: Controller Tests
```bash
# Update route references, then run
rails test test/controllers/
```

### Phase 3: Integration Tests
```bash
# Full integration tests
rails test test/integration/
```

### Phase 4: Manual Testing Checklist
- [ ] Authentication (sign in, OAuth)
- [ ] Event creation
- [ ] Event ticketing and purchases
- [ ] Organisation management
- [ ] File uploads
- [ ] Email sending (pmails)
- [ ] Background jobs
- [ ] Admin interface
- [ ] Payment webhooks (Stripe, GoCardless)
- [ ] Search functionality
- [ ] API endpoints

---

## 8. Rollback Plan

### If Migration Fails

**Option A: Revert to Padrino**
1. Keep Padrino branch in git
2. Switch back: `git checkout padrino-main`
3. Deploy Padrino version

**Option B: Parallel Deployment**
1. Run Rails and Padrino in parallel
2. Route traffic with feature flag
3. Gradually migrate users to Rails

### Git Strategy

```bash
# Create migration branch
git checkout -b rails-8.1-migration

# Keep main branch on Padrino
git checkout main

# Test migration branch thoroughly before merging
```

---

## 9. Post-Migration Optimization

### Optional Improvements (After Migration Stable)

1. **Replace Dragonfly with ActiveStorage**
   - Better Rails integration
   - Direct S3 uploads
   - Image variants

2. **Use Rails 8 Authentication** (instead of custom OmniAuth setup)
   - Simplified authentication
   - Built-in current_user helpers

3. **Migrate to Solid Queue** (instead of Delayed Job)
   - Rails 8 default background job system
   - Better performance

4. **Use Hotwire/Turbo** (instead of jQuery/AJAX)
   - Modern SPA-like experience
   - Less JavaScript

5. **API Mode Controllers** (for API endpoints)
   - Lighter controllers for JSON responses

6. **Asset Pipeline Migration**
   - Use Propshaft or importmap-rails
   - Eliminate CDN dependencies

---

## Summary

### Code Change Estimate (with Sinatra DSL)

| Component | Files Changed | Lines Changed | Lines Added | Difficulty |
|-----------|---------------|---------------|-------------|------------|
| Controllers | 49 | ~200 (wrapper only) | ~100 (class + include) | **Low** |
| Routes | 1 new | 0 | ~700 | Low |
| Config | 15 new | 0 | ~800 | Low |
| Helpers | 7 | ~200 | ~100 | Low |
| Models | 0 | 0 | 0 | None |
| Views | 10-20 | ~100 | 0 | Low |
| Tests | 20 | ~200 | ~100 | Low |
| **Total** | **~100** | **~700** | **~1,800** | **Low-Medium** |

**Key Point:** By keeping Sinatra DSL, controller logic stays 100% unchanged! Only class wrapper changes.

### Timeline Estimate

- **Preparation:** 1 day
- **Rails Setup & Config:** 2-3 days
- **Controller Migration:** 2-3 days (just wrapping in classes - mechanical change)
- **Routes Definition:** 2-3 days
- **Testing & Debugging:** 3-5 days
- **Deployment:** 1-2 days

**Total:** ~2-3 weeks for complete migration with testing (reduced from 3-4 weeks)

### Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| Route mapping errors | Medium | High | Comprehensive route inventory + tests |
| Auth breaking | Low | High | Test auth first, keep sessions compatible |
| Gem incompatibility | Low | Medium | Audit gems before migration |
| Background jobs failing | Low | Medium | Test DJ thoroughly |
| Performance regression | Low | Medium | Load test before production |

### Success Criteria

- ✅ All existing tests pass
- ✅ All routes work identically to Padrino version
- ✅ Authentication works (sign in, OAuth)
- ✅ Payments process correctly
- ✅ Background jobs run
- ✅ Admin interface accessible
- ✅ No data loss or corruption
- ✅ Performance equal or better than Padrino

---

## Appendix A: Route Inventory Template

```ruby
# To be populated from all 49 controller files

# Events (events.rb)
GET /events → events#index
GET /e/:id → events#show
POST /events/new → events#create
GET /e/:id/edit → events#edit
POST /e/:id/edit → events#update
# ... ~50 more event routes

# Organisations (organisations.rb)
GET /organisations → organisations#index
GET /o/:slug → organisations#show
# ... ~40 more org routes

# ... etc for all 49 controllers
# Estimated total: 500-800 routes
```

---

## Appendix B: Controller Conversion Template (with Sinatra DSL)

**Before (Padrino):**
```ruby
Dandelion::App.controller do
  get '/resource' do
    @items = Model.all
    erb :'resource/index'
  end

  post '/resource/new' do
    @item = Model.create(params[:item])
    redirect "/resource/#{@item.id}"
  end
end
```

**After (Rails with Sinatra DSL):**
```ruby
class ResourceController < ApplicationController
  include Sinatra::DSL

  # EXACT SAME CODE - just wrapped in class!
  get '/resource' do
    @items = Model.all
    erb :'resource/index'
  end

  post '/resource/new' do
    @item = Model.create(params[:item])
    redirect "/resource/#{@item.id}"
  end
end
```

**Changes made:**
1. Line 1: `Dandelion::App.controller do` → `class ResourceController < ApplicationController`
2. Line 2: Added `include Sinatra::DSL`
3. Lines 4-15: **UNCHANGED** - identical code
4. Line 16: `end` → `end` (closes class instead of controller block)

**Route mapping (in config/routes.rb):**
```ruby
# Map Sinatra-style routes to Rails
get '/resource', to: 'resource#get_resource'
post '/resource/new', to: 'resource#post_resource_new'
```

---

## Next Steps

1. **Review this plan** with your team
2. **Audit all routes** - create complete route inventory
3. **Set up Rails 8.1 branch** - parallel to existing code
4. **Start with Phase 1** - preparation and auditing
5. **Migrate incrementally** - one controller at a time
6. **Test continuously** - ensure each piece works before moving on

This migration is **highly feasible** and can be done with **minimal disruption** to your existing codebase. The key is preserving the MongoDB/Mongoid layer and controller logic while adopting Rails' structure and conventions.
