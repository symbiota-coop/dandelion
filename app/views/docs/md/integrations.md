Dandelion can connect to other apps via [Zapier](https://zapier.com/apps/dandelion/), to AI assistants via the [Model Context Protocol](https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro) (MCP), and to your own code via the [query API](#query-api). All three use the same API key from your [profile edit page](/accounts/edit).

All access is read-only. Email addresses are included only when you are allowed to view them.

## Zapier

The [Dandelion Zapier integration](https://zapier.com/apps/dandelion/) lets you send Dandelion data to thousands of other apps.

<a href="https://zapier.com/apps/dandelion/"><img src="/images/zapier.png" class="w-100"></a>

| Trigger | Description | Endpoint |
|---------|-------------|----------|
| Order Confirmed | Triggers when someone purchases tickets to your event | `/z/organisation_event_orders` |
| Ticket Confirmed | Triggers when a ticket is issued for your event | `/z/organisation_event_tickets` |
| New Follower | Triggers when someone follows your organisation | `/z/organisation_followers` |

Zapier also calls `/z` to identify the signed-in account and `/z/organisation_events` to list events you can pick from.

## MCP

AI assistants can use Dandelion's MCP server to search and look up public records, and — with your API key — to read admin data for organisations and events you manage.

Public tools, which work without authentication:

- Search events (recent and upcoming), organisations, gatherings and accounts
- Look up events, organisations, gatherings and accounts, by slug/username or ID
- Get trending events
- Get upcoming events for an organisation

Authenticated tools, which require your API key as a Bearer token:

- Get the signed-in account
- Get all events hosted or cohosted by an organisation you admin
- Get organisation followers from the last 24 hours
- Get all completed orders for an event you admin
- Get all completed tickets for an event you admin
- List, query and count [query API](#query-api) resources (`list_resources_tool`, `query_resource_tool`, `count_resource_tool`)

Add the server to your AI assistant's MCP configuration:

```
https://dandelion.events/mcp
```

```json
{
  "mcpServers": {
    "dandelion": {
      "url": "https://dandelion.events/mcp",
      "headers": {
        "Authorization": "Bearer YOUR_API_KEY"
      }
    }
  }
}
```

Public tools still work if no key is sent. An invalid key is rejected with HTTP 401.

## Query API

The query API lets you query Dandelion data with MongoDB-style filters. Every request needs your API key as a Bearer token:

```
Authorization: Bearer YOUR_API_KEY
```

Requests without a key get HTTP 401. Signing in on the website does not authenticate API requests.

### Resources

Each resource is a collection. Rows are filtered by a per-collection read policy (like row-level security in Postgres), so you only ever see records you are allowed to see, and every field returned is one you are allowed to read.

| Resource | Rows you can read |
|----------|-------------------|
| `events` | Public events, plus events you administer (including secret and locked events) |
| `organisations` | All organisations |
| `gatherings` | Listed, non-secret gatherings, plus gatherings you are a member of |
| `accounts` | Public accounts, plus your own (name and username only, never email) |
| `orders` | Your own orders, plus completed orders for events you administer |
| `tickets` | Your own tickets, tickets in orders you placed, plus completed tickets for events you administer |
| `organisationships` | Organisations you follow, plus the followers of organisations you administer |

`GET /api/resources` lists every resource with its readable `fields` and its `filterable_fields`. Some readable fields, such as `url`, `email` or `answers`, cannot be used in filters or sorts, because whether you can see them depends on the row. Emails in `orders` and `tickets` follow the same privacy rules as the rest of Dandelion, so they may be empty.

### Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/resources` | List resources and their fields |
| `POST /api/:resource/find` | Find records |
| `POST /api/:resource/count` | Count records |
| `GET /api/:resource/:id` | Get one record by ID |

`find` takes a JSON body. Every key is optional:

| Key | Description |
|-----|-------------|
| `filter` | MongoDB-style filter on filterable fields |
| `fields` | Fields to return (default: all readable fields; `id` is always included) |
| `sort` | For example `{"start_time": 1}`. Use `1`/`"asc"` or `-1`/`"desc"`. Default: newest first |
| `limit` | Default 20, max 100 |
| `skip` | For paging, max 10,000 |

`count` takes only `filter`.

```
curl -X POST https://dandelion.events/api/orders/find \
  -H "Authorization: Bearer YOUR_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"filter": {"event_id": "507f1f77bcf86cd799439012", "created_at": {"$gte": "2024-01-01"}}, "fields": ["name", "email", "value"], "limit": 50}'
```

```json
{
  "resource": "orders",
  "data": [
    {
      "id": "507f1f77bcf86cd799439015",
      "name": "Alice Johnson",
      "email": "alice@example.com",
      "value": 25.0
    }
  ],
  "limit": 50,
  "skip": 0,
  "has_more": false
}
```

### Filters

Filters use MongoDB query syntax and are always combined with the resource's own restrictions, so a filter can only narrow what you can already see. IDs and dates can be given as strings.

- Top-level operators: `$and`, `$or`, `$nor`
- Field operators: `$eq`, `$ne`, `$gt`, `$gte`, `$lt`, `$lte`, `$in`, `$nin`, `$exists`, `$not`, `$regex` (text fields only, with `$options` of `i`, `m`, `s` or `x`), `$all`, `$size`

Any other operator (such as `$where` or `$expr`) and any field that isn't filterable is rejected with HTTP 400 and a message explaining why. Filters can be nested up to 5 levels deep. Queries that run for more than 5 seconds are stopped with HTTP 504.

```json
{
  "filter": {
    "$or": [
      { "name": { "$regex": "workshop", "$options": "i" } },
      { "location": "Online" }
    ],
    "start_time": { "$gte": "2026-01-01" }
  },
  "sort": { "start_time": 1 }
}
```

Requests are limited to 120 per minute per API key. The API is read-only.

## Account

Returns the authenticated account.

- Zapier: `GET /z`
- MCP: `get_me_tool`

```json
{
  "id": "507f1f77bcf86cd799439011",
  "name": "Jane Smith",
  "username": "jane-smith",
  "email": "jane@example.com",
  "url": "https://dandelion.events/u/jane-smith"
}
```

## Organisation events

Returns all events hosted or cohosted by an organisation you admin, most recent first.

- Zapier: `GET /z/organisation_events` with organisation `slug` or `id` (`organisation_slug` / `organisation_id` also work)
- MCP: `get_organisation_events_tool` with organisation `slug` or `id`

```json
[
  {
    "id": "507f1f77bcf86cd799439012",
    "name": "Summer Workshop (Sat 15 Jun, 2pm–5pm)",
    "slug": "summer-workshop"
  }
]
```

## Organisation followers

Returns new followers from the last 24 hours, most recent first.

- Zapier: `GET /z/organisation_followers` with organisation `slug` or `id` (`organisation_slug` / `organisation_id` also work)
- MCP: `get_organisation_followers_tool` with organisation `slug` or `id`

```json
[
  {
    "id": "507f1f77bcf86cd799439014",
    "name": "John Doe",
    "firstname": "John",
    "lastname": "Doe",
    "email": "john@example.com",
    "created_at": "2024-01-15T10:30:00Z"
  }
]
```

## Event orders

Returns all completed orders for an event you admin, most recent first.

- Zapier: `GET /z/organisation_event_orders` with event `slug` or `id` (`event_slug` / `event_id` also work)
- MCP: `get_event_orders_tool` with event `slug` or `id`

```json
[
  {
    "id": "507f1f77bcf86cd799439015",
    "name": "Alice Johnson",
    "firstname": "Alice",
    "lastname": "Johnson",
    "email": "alice@example.com",
    "value": 25.00,
    "currency": "GBP",
    "opt_in_organisation": true,
    "opt_in_facilitator": false,
    "hear_about": "Social media",
    "via": "instagram-ad",
    "answers": [["Dietary requirements?", "Vegan"]],
    "created_at": "2024-01-15T14:22:00Z"
  }
]
```

`email` may be empty depending on event privacy settings.

## Event tickets

Returns all completed tickets for an event you admin, most recent first.

- Zapier: `GET /z/organisation_event_tickets` with event `slug` or `id` (`event_slug` / `event_id` also work)
- MCP: `get_event_tickets_tool` with event `slug` or `id`

```json
[
  {
    "id": "507f1f77bcf86cd799439016",
    "name": "Alice Johnson",
    "firstname": "Alice",
    "lastname": "Johnson",
    "email": "alice@example.com",
    "ordered_for_name": "Bob Johnson",
    "ordered_for_email": "bob@example.com",
    "ticket_type": "Standard",
    "price": 25.00,
    "currency": "GBP",
    "checked_in": false,
    "checked_in_at": null,
    "order_id": "507f1f77bcf86cd799439015",
    "created_at": "2024-01-15T14:22:00Z"
  }
]
```

Email fields may be empty depending on event privacy settings.
