Dandelion can connect to other apps via [Zapier](https://zapier.com/apps/dandelion/) and to AI assistants via the [Model Context Protocol](https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro) (MCP). Both use the same API key from your [profile edit page](/accounts/edit).

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
