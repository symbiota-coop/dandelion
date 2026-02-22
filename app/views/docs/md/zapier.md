
The Dandelion Zapier API allows you to integrate Dandelion event data with thousands of other apps. The API uses JSON for request and response formats.

**Base URL:** `https://dandelion.events`

**Authentication:** Session-based authentication via Dandelion account login. The Zapier integration uses OAuth to authenticate users.

## API Endpoints

### GET /z

Returns information about the currently authenticated user.

**Authentication:** Required

**Parameters:** None

**Response:**

```json
{
  "id": "507f1f77bcf86cd799439011",
  "name": "Jane Smith",
  "email": "jane@example.com"
}
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for the account |
| `name` | string | Full name of the user |
| `email` | string | Email address of the user |

---

### GET /z/organisation\_events

Returns a list of live, publicly visible events for a given organisation (including co-hosted events).

**Authentication:** Not required

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `organisation_slug` | string | Yes | The URL slug of the organisation (e.g. `my-organisation`) |

**Example Request:**

```
GET /z/organisation_events?organisation_slug=my-organisation
```

**Response:**

```json
[
  {
    "id": "507f1f77bcf86cd799439012",
    "name": "Summer Workshop (Sat 15 Jun, 2pm–5pm)"
  },
  {
    "id": "507f1f77bcf86cd799439013",
    "name": "Monthly Meetup (Wed 1 Jul, 7pm–9pm)"
  }
]
```

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for the event |
| `name` | string | Event name with date/time details |

**Notes:**

- Events are sorted by start time (most recent first)
- Only live, publicly visible events are returned
- Includes events where the organisation is a co-host

---

### GET /z/organisation\_followers

Returns new followers for an organisation from the last 24 hours.

**Authentication:** Required (must be an admin of the organisation)

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `organisation_slug` | string | Yes | The URL slug of the organisation |

**Example Request:**

```
GET /z/organisation_followers?organisation_slug=my-organisation
```

**Response:**

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

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for the organisationship (follow relationship) |
| `name` | string | Full name of the follower |
| `firstname` | string | First name of the follower |
| `lastname` | string | Last name of the follower |
| `email` | string | Email address of the follower |
| `created_at` | string | ISO 8601 timestamp of when the user followed the organisation |

**Notes:**

- Only returns followers from the last 24 hours
- Results are sorted by creation time (most recent first)

---

### GET /z/organisation\_event\_orders

Returns completed orders for a specific event.

**Authentication:** Required (must be an admin of the event)

**Parameters:**

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `organisation_slug` | string | Yes | The URL slug of the organisation |
| `event_id` | string | Yes | The unique identifier of the event |

**Example Request:**

```
GET /z/organisation_event_orders?organisation_slug=my-organisation&event_id=507f1f77bcf86cd799439012
```

**Response:**

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

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique identifier for the order |
| `name` | string | Full name of the ticket purchaser |
| `firstname` | string | First name of the ticket purchaser |
| `lastname` | string | Last name of the ticket purchaser |
| `email` | string | Email address of the ticket purchaser (may be empty based on privacy settings) |
| `value` | number | Total order value |
| `currency` | string | Three-letter currency code (e.g. GBP, USD, EUR) |
| `opt_in_organisation` | boolean | Whether the purchaser opted in to organisation communications |
| `opt_in_facilitator` | boolean | Whether the purchaser opted in to facilitator communications |
| `hear_about` | string | How the purchaser heard about the event |
| `via` | string | Tracking parameter from URL (e.g. `?via=newsletter`) |
| `answers` | array | Custom question responses from the ticket form. Array of `[question, answer]` pairs. |
| `created_at` | string | ISO 8601 timestamp of when the order was created |

**Notes:**

- Only completed (paid) orders are returned
- Results are sorted by creation time (most recent first)
- Email visibility depends on event privacy settings

## Error Responses

The API uses standard HTTP status codes:

| Status Code | Description |
|-------------|-------------|
| `200` | Success |
| `401` | Unauthorized - authentication required |
| `403` | Forbidden - insufficient permissions |
| `404` | Not Found - organisation or event does not exist |

**Error Response Format:**

```json
{
  "error": "Not found"
}
```

## Rate Limiting

API requests are subject to rate limiting. If you exceed the rate limit, you will receive a `429 Too Many Requests` response. Please implement exponential backoff in your integrations.

## Zapier Integration Triggers

The following triggers are available in the Dandelion Zapier integration:

| Trigger | Description | Endpoint |
|---------|-------------|----------|
| New Follower | Triggers when someone follows your organisation | `/z/organisation_followers` |
| New Order | Triggers when someone purchases tickets to your event | `/z/organisation_event_orders` |

## Support

For API support or questions about the Zapier integration, please [contact us](mailto:contact@dandelion.earth).
