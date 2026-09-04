## Creating an organisation

Click Organisations > Create an organisation in the sidebar. Provide the basic details for the organisation and click Save and continue. You will then notice a new dropdown for your organisation containing further admin options at the top of the main window.

The organisation currency defaults to your local currency and can be changed in the Payments tab.

## Roles and privileges

Three roles control who can manage an organisation and its events.

**Organisation admin** — full control of the organisation. Add admins from the organisation page (plus icon next to Admins).

**Event manager** — can create and edit events across the organisation, without access to organisation settings, followers, or the organisation mailer. Toggle this on the Followers page.

**Event admin** — can edit a specific event, handle tickets and orders, check people in, email attendees, and so on. You become an event admin by creating the event, being added as a facilitator, or being set as its organiser, coordinator, or revenue sharer.

Organisation admins and event managers of the host organisation (or a co-host) are automatically event admins of every event. Admins of an activity or local group are event admins of events in that activity or local group.

A facilitator becomes an event admin of that event. Adding someone as a facilitator also lists them on the event page, emails them when orders and waitlist registrations come in (if those notifications are on), lets attendees opt in to their personal email list, and — once they have received feedback — includes them on the [Facilitators](/facilitators) page.

| | Organisation admin | Event manager | Event admin |
| --- | --- | --- | --- |
| Edit organisation settings | Yes | — | — |
| Manage followers, credits and bans | Yes | — | — |
| Add or remove organisation admins | Yes | — | — |
| Grant event manager | Yes | — | — |
| Organisation mailer | Yes | — | — |
| Organisation-wide orders and discount codes | Yes | — | — |
| Activities, local groups, carousels and tiers | Yes | — | — |
| Delete the organisation | Yes | — | — |
| Delete events | Any | Ones they created | — |
| Create events | Yes | Yes | — |
| Event stats for all organisation events | Yes | Yes | — |
| Feature events / change who can see emails | Yes | Yes | — |
| Publish locked or submitted events | Yes | Yes | — |
| Edit events | All | All | Only events they're an admin of |
| Email attendees of an event | Yes | Yes | Yes |
| Check people in | Yes | Yes | Yes |
| See attendee emails | Always | Always | If enabled on the event |
| Add or remove facilitators | Yes | Yes | Yes |

By default, only organisation admins and event managers can see attendee email addresses. Turn on **Allow all event admins to view attendee emails** on an event if other event admins should see them too.

You can also share a [check-in scanner link](/docs/events#checking-people-in) with assistants so they can check people in without becoming event admins.

## Payments

To accept payments for tickets to events created under the organisation, you must add details for Stripe or another payment processor in the Payments tab of your organisation's settings.

## Analytics

In organisation settings under **Analytics**, you can add a Meta/Facebook Pixel ID (digits only). With marketing cookie consent, Dandelion loads the pixel on organisation and event pages, sends `PageView` and `ViewContent` on event pages, and a single `Purchase` after a successful booking. You can also set a pixel on an individual event; if both are set and different, events are sent to both.

## Mailgun

We offer a free gift of 1 email per month for up to 1000 subscribers. Beyond that, you'll need to link a paid [Mailgun](https://www.mailgun.com/) account. (You can always email attendees of events even without linking a Mailgun account.)

After sending a free gift email, open and click rates appear on the sent message page under Mailer. Organisations with their own Mailgun account also get a link through to Mailgun analytics.

For per-link click tracking (including desktop/mobile/tablet), configure a Mailgun `Clicked` webhook to your organisation's webhook URL (shown under Mailgun settings) and paste the HTTP webhook signing key from [API security](https://app.mailgun.com/settings/api_security).

## Community event submissions

In your organisation settings, enable **Allow anyone to submit events for review** so that any signed-in user can propose a new event under your organisation. Those events are not public until an organisation admin or event manager publishes them; organisation admins receive an email when someone submits an event.

## iCal sync

Paste one or more iCal URLs on the **iCal sync** page (organisation dropdown → iCal sync), one per line. Supported hosts: Luma (`api.luma.com`, `api2.luma.com`), Google Calendar, Outlook, and iCloud. Dandelion will import upcoming events for that organisation when you save, and then keep them in sync automatically.

Imported events use the feed's event URL as their RSVP/ticket button, so people can still register on the original platform while discovering the event on Dandelion.

## Recognising monthly donors

Provide a GoCardless access token and/or Patreon API key, and people with active subscriptions will be recognised as monthly donors/members of the organisation.

You can restrict an event to monthly donors by checking **Only allow people making a monthly donation to the organisation to purchase tickets**. Signed-in monthly donors can then buy tickets; others cannot.

## Affiliate credits

Enable affiliate credits to reward attendees for referring others to your events.

1. Go to your organisation settings and set 'Order reward %' (e.g. 10%)
2. Attendees will now receive a personal affiliate link in their order confirmation email
3. For each order made via that link, the referrer earns credit equal to the set percentage of the order value. You cannot earn credit on your own orders.
4. Credit is automatically applied at checkout when the referrer purchases tickets to future events

**For attendees:** If you have credit, your balance is shown on the organisation page. Click it to see a breakdown of credits earned and used.

**For admins:** View and manage credit balances from the Followers page in the organisation dropdown.

## Activities

Activities are used for bundling families of similar events. To create a new activity, go to the organisation dropdown and click Activities, then Create an activity.

If an activity is marked as application-only, only followers of the activity are able to buy tickets, and people can only become followers by having an application accepted.

## Local groups

To create a new local group, go to the organisation dropdown and click Local groups, then Create a local group.

When people that have provided a location follow your organisation, they are added to all relevant local groups.

The Geometry field of a local group accepts a GeoJSON polygon created via [https://geojson.io/](https://geojson.io/). (Copy and paste the contents of the box on the right.)
