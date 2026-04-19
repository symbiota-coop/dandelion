## Creating an organisation

Click Organisations > Create an organisation in the sidebar. Provide the basic details for the organisation and click Save and continue. You will then notice a new dropdown for your organisation containing further admin options at the top of the main window.

## Payments

To accept payments for tickets to events created under the organisation, you must add details for Stripe or another payment processor in the Payments tab of your organisation's settings.

## Mailgun

We offer a free gift of 1 email per month for up to 1000 subscribers. Beyond that, you'll need to link a paid [Mailgun](https://www.mailgun.com/) account. (You can always email attendees of events even without linking a Mailgun account.)

## Community event submissions

In your organisation settings, enable **Allow anyone to submit events for review** so that any signed-in user can propose a new event under your organisation. Those events are not public until an organisation admin publishes them; admins receive an email when someone submits an event.

## iCal sync

Paste one or more iCal URLs on the **iCal sync** page (organisation dropdown → iCal sync), one per line. Dandelion will import upcoming events for that organisation when you save, and then keep them in sync automatically.

Imported events use the feed's event URL as their RSVP/ticket button, so people can still register on the original platform while discovering the event on Dandelion.

## Recognising monthly donors

Provide a GoCardless access token and/or Patreon API key, and people with active subscriptions will be recognised as monthly donors/members of the organisation.

## Affiliate credits

Enable affiliate credits to reward attendees for referring others to your events.

1. Go to your organisation settings and set 'Order reward %' (e.g. 10%)
2. Attendees will now receive a personal affiliate link in their order confirmation email
3. For each order made via that link, the referrer earns credit equal to the set percentage of the order value
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
