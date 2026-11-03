Dandelion can connect to other apps via [Zapier](https://zapier.com/apps/dandelion/) and to AI assistants via the [Model Context Protocol](https://modelcontextprotocol.io/docs/2026-07-28/getting-started/intro) (MCP). Both use the same API key, from the [API keys tab](/accounts/api_key) of your account settings, which shows it once you've entered a sign in code we email you. <!-- claim: zapier-and-mcp-same-api-key -->

Admin data is read-only. <!-- claim: admin-data-read-only --> Email addresses are included only when you are allowed to view them. <!-- claim: emails-only-when-allowed -->

## Zapier

The [Dandelion Zapier integration](https://zapier.com/apps/dandelion/) lets you send Dandelion data to thousands of other apps.

<a href="https://zapier.com/apps/dandelion/"><img alt="Dandelion on Zapier" src="/images/zapier.png" class="w-100"></a>

| Trigger | Description | Endpoint |
|---------|-------------|----------|
| Order Confirmed | Triggers when someone purchases tickets to your event | `/z/organisation_event_orders` | <!-- claim: zapier-order-confirmed -->
| Order Confirmed (Organisation) | Triggers when someone purchases tickets to any event your organisation hosts or cohosts, including events created later | `/z/organisation_orders` | <!-- claim: zapier-order-confirmed-organisation -->
| Ticket Confirmed | Triggers when a ticket is issued for your event | `/z/organisation_event_tickets` | <!-- claim: zapier-ticket-confirmed -->
| New Follower | Triggers when someone follows your organisation | `/z/organisation_followers` | <!-- claim: zapier-new-follower -->

Zapier also calls `/z` to identify the signed-in account and `/z/organisation_events` to list events you can pick from. <!-- claim: zapier-identifies-account-and-lists-events -->

## MCP

AI assistants can use Dandelion's MCP server to search and look up public records, to book events, and — with your API key — to book events as you and to read admin data for organisations and events you manage.

Public tools, which work without authentication:

- Search events (recent and upcoming), organisations, gatherings and accounts <!-- claim: search-tools -->
- Look up events, organisations, gatherings and accounts, by slug/username or ID. <!-- claim: look-up-by-slug-or-id --> Events include their currency and public ticket types <!-- claim: events-include-currency-ticket-types -->
- Get what booking an event involves: [checkout requirements](#checkout-requirements)
- Get trending events <!-- claim: trending-events -->
- Get upcoming events for an organisation <!-- claim: organisation-upcoming-events -->
- Book tickets to an event: [booking](#booking)
- Join the waitlist for a sold-out ticket type or event: [waitlists](#waitlists)

Authenticated tools, which require your API key as a Bearer token: <!-- claim: authenticated-tools-require-key -->

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

Public tools still work if no key is sent. <!-- claim: public-tools-work-without-key --> An invalid key is rejected with HTTP 401. <!-- claim: invalid-key-rejected -->

## Account

Returns the authenticated account. <!-- claim: account-returns-authenticated-account -->

- Zapier: `GET /z` <!-- claim: zapier-get-account -->
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

Returns all events hosted or cohosted by an organisation you admin, most recent first. <!-- claim: organisation-events-returns-events -->

- Zapier: `GET /z/organisation_events` with organisation `slug` or `id` (`organisation_slug` / `organisation_id` also work) <!-- claim: zapier-organisation-events-params -->
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

Returns new followers from the last 24 hours, most recent first. <!-- claim: organisation-followers-last-24-hours -->

- Zapier: `GET /z/organisation_followers` with organisation `slug` or `id` (`organisation_slug` / `organisation_id` also work) <!-- claim: zapier-organisation-followers-params -->
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

Returns the 100 most recently completed orders across all events hosted or cohosted by an organisation you admin, most recently completed first (so an order whose payment confirms later still appears), in the same format as [event orders](#event-orders). <!-- claim: organisation-orders-most-recently-completed --> Use it to send every booking to another app with one Zap, rather than one per event.

- Zapier: `GET /z/organisation_orders` with organisation `slug` or `id` (`organisation_slug` / `organisation_id` also work) <!-- claim: zapier-organisation-orders-params -->
- MCP: `get_organisation_orders_tool` with organisation `slug` or `id`

## Event orders

Returns all completed orders for an event you admin, most recent first. <!-- claim: event-orders-returns-completed-orders -->

- Zapier: `GET /z/organisation_event_orders` with event `slug` or `id` (`event_slug` / `event_id` also work) <!-- claim: zapier-event-orders-params -->
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

`opt_in_organisation` is true when the buyer agreed to receive the organisation's emails. <!-- claim: opt-in-organisation-field --> `completed_at` is null for orders completed before October 2026. <!-- claim: completed-at-null-for-older-orders --> `email` may be empty depending on event privacy settings. <!-- claim: order-email-may-be-empty -->

## Event tickets

Returns all completed tickets for an event you admin, most recent first. <!-- claim: event-tickets-returns-completed-tickets -->

- Zapier: `GET /z/organisation_event_tickets` with event `slug` or `id` (`event_slug` / `event_id` also work) <!-- claim: zapier-event-tickets-params -->
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

Email fields may be empty depending on event privacy settings. <!-- claim: ticket-emails-may-be-empty -->

## Checkout requirements

`get_event_checkout_requirements_tool`, with event `slug` or `id`, says what booking an event involves. <!-- claim: checkout-requirements-says-what-booking-involves --> The booking and waitlist tools, and looking up an event, also take a link to the event as its `slug`. <!-- claim: tools-take-event-link-as-slug --> A secret event is found only by its slug or link, never by its id, and searches leave it out, so an agent can book one when the buyer gives it the link, as anyone with the link can on the event page: <!-- claim: secret-event-found-by-slug-or-link -->

- Whether it can be booked, and why not (sales closed, monthly donors only, members only, no tickets on sale) <!-- claim: requirements-bookable-and-why-not -->
- Its public ticket types: price (fixed, a range, or pay what you want), tickets available, whether each is sold out and when sales end, and whether it has a waitlist to join once it's sold out <!-- claim: requirements-public-ticket-types -->
- Whether the event's own waitlist is open (`event_waitlist`) <!-- claim: requirements-event-waitlist -->
- The buyer details and questions the checkout form asks for, and its opt-ins <!-- claim: requirements-buyer-details-questions-opt-ins -->
- Any donation it offers: to the organisation or to Dandelion, the suggested amount, any `minimum`, and whether a donation is `required`. <!-- claim: requirements-donation --> One to Dandelion is optional, but at least the currency's smallest unit, like £1, which is `added_by_default` to paid tickets <!-- claim: donation-to-dandelion-minimum-smallest-unit -->
- Whether it takes discount codes, and any terms to accept <!-- claim: requirements-discount-codes-and-terms -->
- The payment methods on offer, with whether each works for agent bookings (`agent_checkout`) and whether it's only for when nothing is left to pay (`free_only`, like RSVP) <!-- claim: requirements-payment-methods -->

Pass `secret_ticket_type_id` (a hidden ticket type's secret link, or the `ticket_type_id` in it) to list the ticket type it unlocks, and `discount_code` to see whether a code is valid, what it takes off and which ticket types it applies to. <!-- claim: requirements-secret-ticket-type-and-discount-code -->

## Booking

`create_checkout_tool` books tickets to an event. With your API key, it books as you, updating your phone, postcode and country from `buyer` as the checkout form updates the signed-in account's. <!-- claim: checkout-books-as-you-with-api-key --> Without one, it books for the `buyer` given (their name and email, and the other `buyer_fields`), as the checkout form books for someone signed out, creating an account for a new email. <!-- claim: checkout-books-for-buyer-without-api-key -->

It takes:

- Ticket quantities by ticket type id
- `prices`: the price per ticket the buyer chose for range and pay-what-you-want tickets, by ticket type id. Agents don't choose one for them <!-- claim: checkout-prices-chosen-by-buyer -->
- Answers to the event's questions, by index <!-- claim: checkout-answers-by-index -->
- `opt_ins`: the opt-ins the buyer chose <!-- claim: checkout-opt-ins -->
- `hear_about` in `buyer`, when the event asks it (with your API key too) <!-- claim: checkout-hear-about -->
- `accept_terms`, when the terms must be accepted <!-- claim: checkout-accept-terms -->

And optionally:

- `discount_code`
- `payment_method`: the one the buyer chose, which must have `agent_checkout`; otherwise the first that pays by link <!-- claim: checkout-payment-method -->
- `secret_ticket_type_id`, to book a hidden ticket type <!-- claim: checkout-secret-ticket-type -->
- `donation_amount`: the donation the buyer chose, at least the donation's `minimum` when it has one. <!-- claim: checkout-donation-amount-minimum --> Left out where the donation goes to Dandelion, the booking adds its `minimum`: tell the buyer it's included and optional, and pass `0` if they don't want it <!-- claim: checkout-dandelion-donation-added-by-default -->
- `confirm_duplicate`, when the buyer confirms booking again though they already have a ticket <!-- claim: checkout-confirm-duplicate -->
- `confirm_email`, when the buyer confirms an email address that looks mistyped (one or two keystrokes from a common provider's, like `gmial.com`, which the checkout form also asks about) <!-- claim: checkout-confirm-email -->
- `attribution`: `cohost`, `affiliate_type`, `affiliate_id`, `utm_source`, `utm_medium` and `utm_campaign`, from the link the buyer followed <!-- claim: checkout-attribution -->
- `idempotency_key`, so that a retry returns the first order rather than booking twice (`processing` while it's still being set up, or `expired` if it went unpaid, when booking again needs a new key). <!-- claim: idempotency-retry-returns-first-order --> If the first try failed, a retry books again. <!-- claim: idempotency-failed-retry-books-again --> Without your API key, a retry returns only the order's id and status, not its details or `checkout_url` <!-- claim: idempotency-retry-without-key-id-and-status -->

Free bookings are confirmed straight away. <!-- claim: free-bookings-confirmed --> Paid ones return a `checkout_url` where you pay with the event's card, bank or PayPal provider; unpaid orders are released after an hour (`pay_by`). <!-- claim: paid-bookings-checkout-url-pay-by --> The order says what discounts, credit and donation it includes. <!-- claim: order-includes-discounts-credit-donation --> When the buyer has to finish on the event page (no payment method agents can use, or an event only some can book), the error links to it with their choices filled in. <!-- claim: error-links-to-event-page --> Orders are marked as coming via `mcp`. <!-- claim: orders-via-mcp -->

## Waitlists

`join_waitlist_tool` joins the waitlist for a sold-out ticket type (with its `ticket_type_id`), or for a sold-out event (without one). <!-- claim: join-waitlist-sold-out-ticket-type-or-event --> With your API key, it joins as you; without one, for the `buyer` given (name and email). <!-- claim: join-waitlist-as-you-or-buyer --> They're emailed when tickets become available. <!-- claim: waitlist-emailed-when-available -->
