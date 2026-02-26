
The [Dandelion Zapier integration](https://zapier.com/apps/dandelion/) allows you to integrate Dandelion with thousands of other apps. You'll need your API key, which you can find on your [profile edit page](/accounts/edit).

<a href="https://zapier.com/apps/dandelion/"><img src="/images/zapier.png" class="w-100"></a>

## Zapier Integration Triggers

The following triggers are available in the Dandelion Zapier integration:

| Trigger | Description | Endpoint |
|---------|-------------|----------|
| Order Confirmed | Triggers when someone purchases tickets to your event | `/z/organisation_event_orders` |
| New Follower | Triggers when someone follows your organisation | `/z/organisation_followers` |

## API Endpoints

The API endpoints behind the Zapier triggers. For reference only– Zapier handles all the complexity!

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

Returns a list of events for a given organisation (including co-hosted events).

**Authentication:** Required (must be an admin of the organisation)

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
- Includes all events where the organisation is host or co-host

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
