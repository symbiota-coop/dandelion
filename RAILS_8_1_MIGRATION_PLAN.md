# Rails 8.1 Migration Plan for Dandelion

## Executive Summary

This plan outlines migrating the Dandelion Padrino/Sinatra application to Rails 8.1 while **minimizing code changes**. The strategy preserves:
- MongoDB/Mongoid database layer (no migration to SQL needed)
- Sinatra-style controller syntax (`get '..', post '..'`)
- Existing view templates (ERB)
- Model architecture with concerns
- Helper organization

**Estimated Total Code Changes:** ~2,000-3,000 lines (mostly new Rails configuration and route definitions)

**Files Requiring Modification:** ~50-70 files
**Files Remaining Unchanged:** ~550+ files (85 models, 482 views mostly untouched)

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

Rails 8.1 can accommodate most of your existing patterns:

1. **Sinatra-style Routes:** Rails supports this via routing DSL
2. **Mongoid:** Fully compatible with Rails 8.1
3. **ERB Templates:** 100% compatible
4. **Helpers:** Convert to Rails helpers (minor syntax changes)
5. **Middleware:** Rails Rack middleware stack works identically

### What Changes vs. What Stays

| Component | Change Level | Strategy |
|-----------|-------------|----------|
| Models (85 files) | **Minimal** | Change `Mongoid::Document` includes, keep all logic |
| Controllers (49 files) | **Moderate** | Convert to Rails controllers, preserve route handlers |
| Views (482 files) | **Minimal** | Update helper calls, keep templates |
| Helpers (7 files) | **Light** | Convert to Rails helper modules |
| Routes | **New** | Create `config/routes.rb` mapping all existing routes |
| Config | **New** | Rails standard config structure |
| Gemfile | **Moderate** | Swap Padrino for Rails, update incompatible gems |

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
- Migrate models (add `ApplicationRecord` equivalent)
- Convert controllers to Rails controllers
- Update helpers
- Create routes.rb mapping

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
gem 'sinatra'
```

**With:**
```ruby
gem 'rails', '~> 8.1.0'
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

### Step 5: Convert Controllers (Sinatra → Rails)

**Strategy:** Create one Rails controller per Padrino controller file, preserving action logic.

**Example: app/controllers/events.rb (Padrino):**
```ruby
Dandelion::App.controller do
  get '/events', provides: %i[html ics json] do
    @events = Event.live.public.browsable
    @from = params[:from] ? parse_date(params[:from]) : Date.today

    respond_to do |format|
      format.html do
        @events = @events.future(@from)
        if request.xhr?
          render partial: 'events/events'
        else
          render 'events/events'
        end
      end
      format.json { render json: map_json(@events) }
      format.ics { render plain: @events.to_ical }
    end
  end

  post '/events/new' do
    @event = Event.new(mass_assigning(params[:event], Event))
    if @event.save
      redirect_to event_path(@event.slug)
    else
      render 'events/build'
    end
  end
end
```

**Becomes: app/controllers/events_controller.rb (Rails):**
```ruby
class EventsController < ApplicationController
  # Same logic, different wrapper

  def index
    @events = Event.live.public.browsable
    @from = params[:from] ? parse_date(params[:from]) : Date.today

    respond_to do |format|
      format.html do
        @events = @events.future(@from)
        if request.xhr?
          render partial: 'events/events'
        else
          render 'events/events'
        end
      end
      format.json { render json: map_json(@events) }
      format.ics { render plain: @events.to_ical }
    end
  end

  def create
    @event = Event.new(mass_assigning(params[:event], Event))
    if @event.save
      redirect_to event_path(@event.slug)
    else
      render 'events/build'
    end
  end
end
```

**Key Conversions:**
- `get '/path' do` → `def action_name`
- `post '/path' do` → `def create` or `def custom_action`
- `params` → `params` (same!)
- `redirect '/path'` → `redirect_to path_helper`
- `erb :'view'` → `render 'view'`
- `partial :'view'` → `render partial: 'view'`
- `content_type :json` → `respond_to do |format|`

### Step 6: Create Routes File

**config/routes.rb:**
```ruby
Rails.application.routes.draw do
  # Mount admin interface
  mount ActivateAdmin::Engine, at: '/dadmin'

  # Events
  get '/events', to: 'events#index', as: 'events'
  post '/events/new', to: 'events#create'
  get '/e/:id', to: 'events#show', as: 'event'
  get '/e/:id/edit', to: 'events#edit', as: 'edit_event'
  post '/e/:id/edit', to: 'events#update'
  post '/e/:id/destroy', to: 'events#destroy'

  # Organisations
  get '/organisations', to: 'organisations#index', as: 'organisations'
  get '/o/:slug', to: 'organisations#show', as: 'organisation'
  get '/o/:slug/edit', to: 'organisations#edit'
  post '/o/:slug/edit', to: 'organisations#update'

  # Activities
  get '/o/:organisation_slug/activities', to: 'activities#index'
  get '/o/:organisation_slug/a/:slug', to: 'activities#show', as: 'activity'

  # ... map all 500+ routes from existing controllers

  # Accounts/Auth
  get '/sign_in', to: 'auth#sign_in', as: 'sign_in'
  post '/sign_in', to: 'auth#create_session'
  get '/sign_out', to: 'auth#sign_out', as: 'sign_out'

  # OmniAuth callbacks
  get '/auth/:provider/callback', to: 'auth#omniauth_callback'
  post '/auth/:provider/callback', to: 'auth#omniauth_callback'

  # Webhooks
  post '/incoming/stripe', to: 'webhooks#stripe'
  post '/incoming/mailgun', to: 'webhooks#mailgun'
  post '/incoming/gocardless', to: 'webhooks#gocardless'

  # API routes
  namespace :api do
    namespace :v1 do
      resources :events, only: [:index, :show]
      resources :organisations, only: [:index, :show]
    end
  end

  root to: 'home#index'
end
```

**Route Generation Strategy:**
1. Extract all `get`, `post`, `put`, `delete` routes from 49 controller files
2. Map each to a Rails route with appropriate controller#action
3. Preserve custom route names and URL patterns
4. Group by resource for clarity

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
| `padrino` | **Remove** → `rails` | Routing, controllers |
| `sinatra` | **Remove** (absorbed by Rails) | None |
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
- `sinatra`
- `activesupport` (Rails includes it)

**Gems to Add:**
- `rails` ~> 8.1.0

**Total Gemfile changes:** ~5 lines

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

**Controllers (49 files):**
- Rename: `app/controllers/*.rb` → `app/controllers/*_controller.rb`
- Convert: `Dandelion::App.controller do` → `class XController < ApplicationController`
- Convert: `get/post` blocks → `def action_name`
- Update: Redirect/render syntax

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

### Code Change Estimate

| Component | Files Changed | Lines Changed | Lines Added | Difficulty |
|-----------|---------------|---------------|-------------|------------|
| Controllers | 49 | ~1,000 | ~500 | Medium |
| Routes | 1 new | 0 | ~700 | Low |
| Config | 15 new | 0 | ~800 | Low |
| Helpers | 7 | ~200 | ~100 | Low |
| Models | 0 | 0 | 0 | None |
| Views | 10-20 | ~100 | 0 | Low |
| Tests | 20 | ~200 | ~100 | Low |
| **Total** | **~100** | **~1,500** | **~2,200** | **Medium** |

### Timeline Estimate

- **Preparation:** 1-2 days
- **Rails Setup & Config:** 2-3 days
- **Controller Migration:** 5-7 days (49 controllers)
- **Routes Definition:** 2-3 days
- **Testing & Debugging:** 5-7 days
- **Deployment:** 1-2 days

**Total:** ~3-4 weeks for complete migration with testing

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

## Appendix B: Controller Conversion Template

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

**After (Rails):**
```ruby
class ResourceController < ApplicationController
  def index
    @items = Model.all
    render 'resource/index'
  end

  def create
    @item = Model.create(params[:item])
    redirect_to resource_path(@item.id)
  end
end
```

**Route mapping:**
```ruby
get '/resource', to: 'resource#index'
post '/resource/new', to: 'resource#create'
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
