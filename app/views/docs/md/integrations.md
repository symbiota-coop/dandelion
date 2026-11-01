Dandelion can connect to other apps via [Zapier](https://zapier.com/apps/dandelion/) and to AI assistants via the [Model Context Protocol](https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro) (MCP). Both use the same API key, from the [API keys tab](/accounts/api_key) of your account settings, which shows it once you've entered a sign in code we email you.

All access is read-only. Email addresses are included only when you are allowed to view them.

## Zapier

The [Dandelion Zapier integration](https://zapier.com/apps/dandelion/) lets you send Dandelion data to thousands of other apps.

<a href="https://zapier.com/apps/dandelion/"><img alt="Dandelion on Zapier" src="/images/zapier.png" class="w-100"></a>

| Trigger | Description | Endpoint |
|---------|-------------|----------|
| Order Confirmed | Triggers when someone purchases tickets to your event | `/z/organisation_event_orders` |
| Order Confirmed (Organisation) | Triggers when someone purchases tickets to any event your organisation hosts or cohosts, including events created later | `/z/organisation_orders` |
| Ticket Confirmed | Triggers when a ticket is issued for your event | `/z/organisation_event_tickets` |
| New Follower | Triggers when someone follows your organisation | `/z/organisation_followers` |

Zapier also calls `/z` to identify the signed-in account and `/z/organisation_events` to list events you can pick from.

## MCP

AI assistants can use Dandelion's MCP server to search and look up public records, to book events, and — with your API key — to book events as you and to read admin data for organisations and events you manage.

Public tools, which work without authentication:

- Search events (recent and upcoming), organisations, gatherings and accounts
- Look up events, organisations, gatherings and accounts, by slug/username or ID. An event comes with its currency and public ticket types: price (fixed, a range, or pay what you want), tickets available, whether it's sold out and when sales end
- Get what booking an event involves (`get_event_checkout_requirements_tool`, by event `slug` or `id`): whether it can be booked and why not (sales closed, monthly donors only, members only, no tickets on sale), its ticket types (with whether each has a waitlist to join once it's sold out), whether the event's own waitlist is open (`event_waitlist`), the buyer details and questions the checkout form asks for, opt-ins, any donation it offers (to the organisation or to Dandelion, the suggested amount and any minimum), whether it takes discount codes, terms and the payment methods on offer, with whether each one works for agent bookings (`agent_checkout`) and whether it's only for when nothing is left to pay (`free_only`, like RSVP). Pass `secret_ticket_type_id` (a hidden ticket type's secret link, or the `ticket_type_id` in it) to list the ticket type it unlocks, and `discount_code` to see whether a code is valid, what it takes off and which ticket types it applies to
- Get trending events
- Get upcoming events for an organisation
- Book tickets to an event (`create_checkout_tool`): with your API key, as you, updating your phone, postcode and country from `buyer` as the checkout form updates the signed-in account's; without one, for the `buyer` given (their name and email, and the other `buyer_fields`), as the checkout form books for someone signed out, creating an account for a new email. Pass ticket quantities by ticket type id, the price per ticket the buyer chose for range and pay-what-you-want tickets (`prices`, by ticket type id: agents don't choose one for them), answers to the event's questions by index, the `opt_ins` the buyer chose, `hear_about` in `buyer` when the event asks it (with your API key too), and `accept_terms` when the terms must be accepted. You can also pass a `discount_code`, the `payment_method` the buyer chose (one with `agent_checkout`; the first that pays by link otherwise), a `secret_ticket_type_id` to book a hidden ticket type, a `donation_amount` the buyer chose (at least the event's minimum, when it asks for one), `confirm_duplicate` when the buyer confirms booking again though they already have a ticket, and `attribution` (`cohost`, `affiliate_type`, `affiliate_id` and `utm_source`, `utm_medium` and `utm_campaign`, from the link the buyer followed). Free bookings are confirmed straight away. Paid ones return a `checkout_url` where you pay with the event's card, bank or PayPal provider; unpaid orders are released after an hour (`pay_by`). The order says what discounts, credit and donation it includes. When the buyer has to finish on the event page (no payment method agents can use, or an event only some can book), the error links to it with their choices filled in. Pass an `idempotency_key` so that a retry returns the first order rather than booking twice (`processing` while it's still being set up, or `expired` if it went unpaid, when booking again needs a new key); if the first try failed, a retry books again. Without your API key, a retry returns only the order's id and status, not its details or `checkout_url`. Orders are marked as coming via `mcp`
- Join the waitlist for a sold-out ticket type, or for a sold-out event (`join_waitlist_tool`, with the ticket type's `ticket_type_id`, or without it for the event's own): with your API key, as you; without one, for the `buyer` given (name and email). They're emailed when tickets become available

Authenticated tools, which require your API key as a Bearer token:

- Get the signed-in account
- Get all events hosted or cohosted by an organisation you admin
- Get organisation followers from the last 24 hours
- Get the latest completed orders across all events of an organisation you admin
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

## Organisation orders

Returns the 100 most recently completed orders across all events hosted or cohosted by an organisation you admin, most recently completed first (so an order whose payment confirms later still appears), in the same format as [event orders](#event-orders). Use it to send every booking to another app with one Zap, rather than one per event.

- Zapier: `GET /z/organisation_orders` with organisation `slug` or `id` (`organisation_slug` / `organisation_id` also work)
- MCP: `get_organisation_orders_tool` with organisation `slug` or `id`

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
    "event_id": "507f1f77bcf86cd799439012",
    "event_name": "Summer Workshop",
    "event_slug": "summer-workshop",
    "event_url": "https://dandelion.events/e/summer-workshop",
    "event_start_time": "2024-06-15T14:00:00Z",
    "completed_at": "2024-01-15T14:25:00Z",
    "created_at": "2024-01-15T14:22:00Z"
  }
]
```

`opt_in_organisation` is true when the buyer agreed to receive the organisation's emails. `completed_at` is null for orders completed before October 2026. `email` may be empty depending on event privacy settings.

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
