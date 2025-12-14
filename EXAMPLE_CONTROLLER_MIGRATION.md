# Example Controller Migration - Events Controller

This document shows the **exact changes** needed to migrate a real controller from Padrino to Rails 8.1 while **keeping the Sinatra syntax**.

## Current File: `app/controllers/events.rb`

**Lines of code:** ~200+ lines
**Routes defined:** ~15+ routes

## Changes Needed

### Before (Padrino):
```ruby
Dandelion::App.controller do
  get '/events', provides: %i[html ics json] do
    @events = Event.live.public.browsable
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil

    content_type = (parts = URI(request.url).path.split('.')
                    parts.length == 2 ? parts.last.to_sym : :html)

    @events = case params[:order]
              when 'created_at'
                @events.order('created_at desc')
              else
                @events.order('start_time asc')
              end
    @events = @events.and(coordinates: { '$geoWithin' => { '$box' => @bounding_box } }) if params[:near] && %w[north south east west].all? { |p| params[p].nil? } && (@bounding_box = calculate_geographic_bounding_box(params[:near]))
    @events = @events.and(:id.in => EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id)) if params[:event_tag_id]
    %i[organisation activity local_group].each do |r|
      @events = @events.and("#{r}_id": params[:"#{r}_id"]) if params[:"#{r}_id"]
    end
    if params[:online]
      @events = @events.online
      params[:in_person] = false
    end
    if params[:in_person]
      @events = @events.in_person
      params[:online] = false
    end
    @events = @events.and(hidden_from_homepage: false) if params[:home]
    @events = @events.and(has_image: true) if params[:images]
    case content_type
    when :html
      @events = @events.future(@from)
      @events = @events.and(:start_time.lt => @to + 1) if @to
      @events = @events.and(:id.in => Event.search(params[:q], @events).pluck(:id)) if params[:q]
      if params[:order] == 'random'
        event_ids = @events.pluck(:id)
        @events = @events.collection.aggregate([
                                                 { '$match' => { '_id' => { '$in' => event_ids } } },
                                                 { '$sample' => { size: event_ids.length } }
                                               ]).map do |hash|
          Event.new(hash.select { |k, _v| Event.fields.keys.include?(k.to_s) })
        end
      elsif params[:order] == 'trending'
        @events = @events.trending(@from)
      end
      if request.xhr?
        partial :'events/events'
      else
        erb :'events/events'
      end
    when :json
      map_json(@events)
    when :ics
      @events.to_ical
    end
  end

  # ... 14+ more route handlers
end
```

### After (Rails 8.1 with Sinatra DSL):

**File renamed to:** `app/controllers/events_controller.rb`

```ruby
class EventsController < ApplicationController
  include Sinatra::DSL

  # EVERYTHING BELOW IS IDENTICAL - ZERO CHANGES!
  get '/events', provides: %i[html ics json] do
    @events = Event.live.public.browsable
    @from = params[:from] ? parse_date(params[:from]) : Date.today
    @to = params[:to] ? parse_date(params[:to]) : nil

    content_type = (parts = URI(request.url).path.split('.')
                    parts.length == 2 ? parts.last.to_sym : :html)

    @events = case params[:order]
              when 'created_at'
                @events.order('created_at desc')
              else
                @events.order('start_time asc')
              end
    @events = @events.and(coordinates: { '$geoWithin' => { '$box' => @bounding_box } }) if params[:near] && %w[north south east west].all? { |p| params[p].nil? } && (@bounding_box = calculate_geographic_bounding_box(params[:near]))
    @events = @events.and(:id.in => EventTagship.and(event_tag_id: params[:event_tag_id]).pluck(:event_id)) if params[:event_tag_id]
    %i[organisation activity local_group].each do |r|
      @events = @events.and("#{r}_id": params[:"#{r}_id"]) if params[:"#{r}_id"]
    end
    if params[:online]
      @events = @events.online
      params[:in_person] = false
    end
    if params[:in_person]
      @events = @events.in_person
      params[:online] = false
    end
    @events = @events.and(hidden_from_homepage: false) if params[:home]
    @events = @events.and(has_image: true) if params[:images]
    case content_type
    when :html
      @events = @events.future(@from)
      @events = @events.and(:start_time.lt => @to + 1) if @to
      @events = @events.and(:id.in => Event.search(params[:q], @events).pluck(:id)) if params[:q]
      if params[:order] == 'random'
        event_ids = @events.pluck(:id)
        @events = @events.collection.aggregate([
                                                 { '$match' => { '_id' => { '$in' => event_ids } } },
                                                 { '$sample' => { size: event_ids.length } }
                                               ]).map do |hash|
          Event.new(hash.select { |k, _v| Event.fields.keys.include?(k.to_s) })
        end
      elsif params[:order] == 'trending'
        @events = @events.trending(@from)
      end
      if request.xhr?
        partial :'events/events'
      else
        erb :'events/events'
      end
    when :json
      map_json(@events)
    when :ics
      @events.to_ical
    end
  end

  # ... 14+ more route handlers - ALL IDENTICAL
end
```

## Summary of Changes

### What Changed:
1. **File renamed:** `events.rb` → `events_controller.rb`
2. **Line 1:** `Dandelion::App.controller do` → `class EventsController < ApplicationController`
3. **Line 2:** Added `include Sinatra::DSL`
4. **Last line:** `end` (closes class instead of controller block)

### What Stayed EXACTLY the Same:
- ✅ All `get/post/put/delete` route definitions
- ✅ All route handler logic (100% unchanged)
- ✅ All method calls (`params`, `request`, `erb`, `partial`, etc.)
- ✅ All business logic
- ✅ All database queries
- ✅ All rendering logic
- ✅ All conditional logic

### Lines Changed: **3 lines** (out of 200+)
### Logic Changed: **0 lines**

## How to Migrate This Controller

### Step 1: Rename File
```bash
mv app/controllers/events.rb app/controllers/events_controller.rb
```

### Step 2: Edit First 2 Lines
```ruby
# Change line 1 from:
Dandelion::App.controller do

# To:
class EventsController < ApplicationController
  include Sinatra::DSL
```

### Step 3: Verify Last Line
The final `end` should close the class (no change needed, just different meaning)

### Step 4: Done!
That's it! The controller is now Rails-compatible while keeping all Sinatra syntax.

## Routes Configuration

Add to `config/routes.rb`:

```ruby
# Events routes
get '/events', to: 'events#get_events', as: 'events'
get '/e/:id', to: 'events#get_e_id', as: 'event'
post '/e/:id/edit', to: 'events#post_e_id_edit'
# ... map remaining routes
```

## Testing

After migration, test that:
- ✅ GET /events works (HTML, JSON, ICS formats)
- ✅ Filtering by date, tags, location works
- ✅ XHR requests return partials
- ✅ All other routes in the controller work identically

## Key Takeaway

**This is a mechanical change, not a rewrite.**

You can migrate all 49 controllers this way:
- 3 line changes per file
- Zero logic changes
- All routes work identically
- All tests should pass immediately

**Estimated time per controller:** 5-10 minutes (mostly testing)
**Total controller migration time:** 2-3 days for all 49 controllers
