## Creating an organisation

Click Organisations > Create an organisation in the sidebar. Provide the basic details for the organisation and click Save and continue. You will then notice a new dropdown for your organisation containing further admin options at the top of the main window.

The organisation currency defaults to your local currency and can be changed in the Payments tab. <!-- claim: currency-defaults-to-local -->

## Roles and privileges

Three roles control who can manage an organisation and its events.

**Organisation admin** — full control of the organisation. Add admins from the organisation page (plus icon next to Admins).

**Event manager** — can create and edit events across the organisation, without access to organisation settings, followers, or the organisation mailer. <!-- claim: event-manager-creates-and-edits-events --> Toggle this on the Followers page.

**Event admin** — can edit a specific event, handle tickets and orders, check people in, email attendees, and so on. You become an event admin by creating the event, being added as a facilitator, or being set as its organiser, coordinator, or revenue sharer. <!-- claim: who-becomes-event-admin -->

Organisation admins and event managers of the host organisation (or a co-host) are automatically event admins of every event. Admins of an activity or local group are event admins of events in that activity or local group. <!-- claim: org-admins-managers-activity-admins-are-event-admins -->

A facilitator becomes an event admin of that event. Adding someone as a facilitator also lists them on the event page, emails them when orders and waitlist registrations come in (if those notifications are on), lets attendees opt in to their personal email list, and — once they have received feedback — includes them on the [Facilitators](/facilitators) page. <!-- claim: facilitator-listed-emailed-opt-in -->

| | Organisation admin | Event manager | Event admin |
| --- | --- | --- | --- |
| Edit organisation settings | Yes | — | — <!-- claim: table-edit-organisation-settings --> |
| Manage followers, credits and bans | Yes | — | — <!-- claim: table-manage-followers-credits-bans --> |
| Add or remove organisation admins | Yes | — | — <!-- claim: table-add-remove-organisation-admins --> |
| Grant event manager | Yes | — | — <!-- claim: table-grant-event-manager --> |
| Organisation mailer | Yes | — | — <!-- claim: table-organisation-mailer --> |
| Organisation-wide orders and discount codes | Yes | — | — <!-- claim: table-organisation-orders-discount-codes --> |
| Activities, local groups, carousels and tiers | Yes | — | — <!-- claim: table-activities-local-groups-carousels-tiers --> |
| Delete the organisation | Yes | — | — <!-- claim: table-delete-organisation --> |
| Delete events | Any | Ones they created | — <!-- claim: table-delete-events --> |
| Create events | Yes | Yes | — <!-- claim: table-create-events --> |
| Event stats for all organisation events | Yes | Yes | — <!-- claim: table-event-stats --> |
| Feature events / change who can see emails | Yes | Yes | — <!-- claim: table-feature-events-show-emails --> |
| Change revenue sharer and profit shares | Yes | Yes | — <!-- claim: table-change-revenue-sharer --> |
| Publish submitted events | Yes | Yes | — <!-- claim: table-publish-submitted --> |
| Unlock locked events | Yes | Yes | Unless the organisation takes event submissions <!-- claim: table-unlock-locked --> |
| Edit events | All | All | Only events they're an admin of |
| Email attendees of an event | Yes | Yes | Yes <!-- claim: table-email-attendees --> |
| Check people in | Yes | Yes | Yes <!-- claim: table-check-in --> |
| See attendee emails | Always | Always | If enabled on the event <!-- claim: table-see-attendee-emails --> |
| Add or remove facilitators | Yes | Yes | Yes <!-- claim: table-add-remove-facilitators --> |

By default, only organisation admins and event managers can see attendee email addresses. <!-- claim: attendee-emails-admins-and-managers-only --> Turn on **Allow all event admins to view attendee emails** on an event if other event admins should see them too. <!-- claim: show-emails-lets-event-admins-see-emails -->

Revenue sharer, ticket-revenue split, and profit-share fields can also be changed by admins of the event's activity or local group. Other event admins (facilitators, organisers, coordinators, revenue sharers, the event creator, and admins of co-host organisations) cannot change them. <!-- claim: revenue-fields-activity-local-group-admins -->

You can also share a [check-in scanner link](/docs/events#checking-people-in) with assistants so they can check people in without becoming event admins. <!-- claim: check-in-scanner-link -->

## Payments

To accept payments for tickets to events created under the organisation, you must add details for Stripe or another payment processor in the Payments tab of your organisation's settings. Stripe is shown by default; click **Set up** for GoCardless, Open Collective, Mollie, PayPal, Crypto or Patreon.

See [Mollie](/docs/events#taking-payments-with-mollie), [PayPal](/docs/events#taking-payments-with-paypal) and [Open Collective](/docs/events#taking-payments-with-open-collective) for setup steps.

GoCardless Instant Bank Pay and instalments are only offered at checkout for **GBP** and **EUR** events (UK and supported Eurozone countries). <!-- claim: gocardless-gbp-eur-only --> For other currencies, use Stripe, Mollie, PayPal, or another processor.

## Analytics

In organisation settings under **Analytics**, you can add a Meta/Facebook Pixel ID (digits only) and a Google Ads conversion ID and label. <!-- claim: analytics-ids --> With marketing cookie consent, Dandelion loads those tags on organisation and event pages. <!-- claim: analytics-tags-need-marketing-consent -->

The Meta pixel sends `PageView` and `ViewContent` on event pages, and a single `Purchase` after a successful booking. <!-- claim: meta-pixel-events --> The Google Ads tag loads on those same pages and fires a single conversion after a successful booking (value, currency, and a unique order ID, so it isn't double-counted). <!-- claim: google-ads-conversion --> If you enable **Google Ads Enhanced Conversions**, the purchase also sends the buyer's hashed email and phone (when we have them) so Google can match the conversion more accurately. <!-- claim: google-ads-enhanced-conversions -->

You can also set these on an individual event; if both organisation and event values are set and different, events are sent to both. <!-- claim: analytics-org-and-event-both-sent -->

## Mailgun

We offer a free gift of 1 email per month to organisations with up to 1000 followers (counting any who've unsubscribed). Beyond that, you'll need to link a paid [Mailgun](https://www.mailgun.com/) account. (You can always email attendees of events even without linking a Mailgun account.) <!-- claim: free-gift-email -->

After sending a free gift email, open and click rates appear on the sent message page under Mailer. Organisations with their own Mailgun account also get a link through to Mailgun analytics. <!-- claim: free-gift-email-analytics -->

To link your account, enter your Mailgun API key, region and sending domain (e.g. `mg.example.com`, from `Sending` > `Domains` in Mailgun). The domain is your own sending domain, not Mailgun's API address (`api.mailgun.net`). <!-- claim: mailgun-sending-domain -->

For per-link click tracking (including desktop/mobile/tablet), configure a Mailgun `Clicked` webhook to your organisation's webhook URL (shown under Mailgun settings) and paste the HTTP webhook signing key from [API security](https://app.mailgun.com/settings/api_security). <!-- claim: mailgun-click-webhook -->

## Community event submissions

In your organisation settings, enable **Allow anyone to submit events for review** so that any signed-in user can propose a new event under your organisation. Those events are not public until an organisation admin or event manager publishes them; organisation admins receive an email when someone submits an event. <!-- claim: community-event-submissions -->

## iCal sync

Paste one or more iCal URLs on the **iCal sync** page (organisation dropdown → iCal sync), one per line. <!-- claim: ical-multiple-urls --> Supported hosts: Luma (`api.luma.com`, `api2.luma.com`), Google Calendar, Outlook, and iCloud. <!-- claim: ical-supported-hosts --> Dandelion will import upcoming events for that organisation when you save, and then keep them in sync automatically. <!-- claim: ical-import-and-sync -->

Imported events use the feed's event URL as their RSVP/ticket button, so people can still register on the original platform while discovering the event on Dandelion. <!-- claim: ical-feed-url-as-rsvp -->

## Recognising monthly donors

On the Payments tab, click **Set up GoCardless** and provide a GoCardless access token, and/or **Set up Patreon** and provide the client ID, client secret and creator's refresh token of a client you create in Patreon's developer portal. People with active subscriptions or pledges will be recognised as monthly donors/members of the organisation, synced each night. <!-- claim: monthly-donors-synced --> Patreon pledges are recorded in the currency each patron pays. <!-- claim: patreon-pledge-currency --> You can also record a monthly donation by hand on the organisation's members page, once GoCardless or Patreon is set up or the organisation has monthly donors; clear the amount when someone stops donating. <!-- claim: monthly-donation-by-hand -->

You can restrict an event to monthly donors by checking **Only allow people making a monthly donation to the organisation to purchase tickets**. Signed-in monthly donors can then buy tickets; others cannot. <!-- claim: monthly-donors-only-events -->

## Affiliate credits

Enable affiliate credits to reward attendees for referring others to your events.

1. Go to your organisation settings and set 'Order reward %' (e.g. 10%)
2. Attendees will now receive a personal affiliate link in their order confirmation email <!-- claim: affiliate-link-in-confirmation -->
3. For each order made via that link, the referrer earns credit equal to the set percentage of the order value. You cannot earn credit on your own orders. <!-- claim: affiliate-credit-percentage -->
4. Credit is automatically applied at checkout when the referrer purchases tickets to future events <!-- claim: credit-applied-at-checkout -->

**For attendees:** If you have credit, your balance is shown on the organisation page. Click it to see a breakdown of credits earned and used. <!-- claim: credit-balance-shown -->

**For admins:** View and manage credit balances from the Followers page in the organisation dropdown.

## Activities

Activities are used for bundling families of similar events. To create a new activity, go to the organisation dropdown and click Activities, then Create an activity.

If an activity is marked as application-only, only followers of the activity are able to buy tickets, and people can only become followers by having an application accepted. <!-- claim: application-only-activities -->

## Local groups

To create a new local group, go to the organisation dropdown and click Local groups, then Create a local group.

When people that have provided a location follow your organisation, they are added to all relevant local groups. <!-- claim: followers-join-local-groups -->

The Geometry field of a local group accepts a GeoJSON polygon created via [https://geojson.io/](https://geojson.io/). (Copy and paste the contents of the box on the right.)
