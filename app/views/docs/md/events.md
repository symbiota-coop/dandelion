## Creating an event

### If you don't already have a Dandelion account

Check out the video below, which does assume you have a [Stripe](https://stripe.com/) account.

<div class="raw-html-embed">
  <div class="embed-responsive embed-responsive-16by9 mb-3">
    <iframe class="embed-responsive-item" src="https://player.vimeo.com/video/1030013082?badge=0&amp;autopause=0&amp;player_id=0&amp;app_id=58479" frameborder="0" allow="autoplay; fullscreen; picture-in-picture; clipboard-write" title="How to create an event on Dandelion" allowfullscreen="">
    </iframe>
  </div>
  <script src="https://player.vimeo.com/api/player.js"></script></div>

> Hi, I'm going to show you how easy it is to set up an event on Dandelion. Start by clicking 'List an event'.
>
> First you'll need to create an account. Fill in some personal details and click 'Sign up'.
>
> OK, you're in! All events on Dandelion are listed under an organisation. Fill in some details of the organisation and click 'Save and continue'.
>
> Connect your Stripe account and click 'Update organisation'.
>
> OK, your organisation is ready! Now let's create an event. Provide an event title, and start and end time.
>
> Click 'Description and confirmation email', and provide an event description and any extra info for the order confirmation email.
>
> Click 'Tickets', and add some ticket types.
>
> Fill in the ticket type name, price and capacity.
>
> That'll do for now - click the final tab and then 'Create event'.
>
> You're done!

<p class="action"><a href="https://dandelion.events/events/new">List an event</a></p>

### If you already have a Dandelion account

Events in Dandelion must be created under an Organisation. (See [Organisations](/docs/organisations) for details on how to create an Organisation.)

- Go to your organisation's page
- Click the organisation dropdown at the top of the main window and select Create an event
- Provide the required details and click Create event. You will then notice a new dropdown containing further admin options for your event at the top of the main window.

## Let attendees choose how much to pay

To let your attendees choose how much to pay for a ticket type:

- Leave the 'Price or range' field of a ticket type blank to allow attendees to pay any amount
- Enter two numbers separated by a dash to create a slider e.g. 5-50 creates a slider where attendees can choose to pay any amount between £5–50 ($/€/etc)

## Allowing people to pay in instalments

The best solution for this is to [enable Klarna on your Stripe account](https://docs.stripe.com/payments/klarna). Customers will then be able to pay for the purchase in three or four interest-free payments at checkout.

Alternatively, you can create a secret ticket type with a quantity equal to the number of instalments and send a link to the attendee. (Make sure you check that they actually end up purchasing all the tickets of this ticket type!)

## Including sales taxes (VAT/MOMS)

First, [add a tax rate on Stripe](https://dashboard.stripe.com/tax-rates) (for the UK, VAT/20%/Inclusive; for Sweden, VAT/25%/Inclusive – leave Region blank to apply to all purchases). Then copy the tax rate ID, and enter it in your event settings under Everything else (or in your organisation settings under Payments to apply to all events in the organisation).

## Sending payment receipts

To enable automated receipts for Stripe payments, toggle 'Successful payments' on in your [customer emails settings](https://dashboard.stripe.com/settings/emails).

## Taking payments with Open Collective

If your organisation has an [Open Collective](https://opencollective.com/) account, you can accept payments through it:

1. Go to the Payments tab in your organisation's settings and enter your Open Collective organisation slug (e.g. if your Open Collective URL is `https://opencollective.com/mystica`, the slug is `mystica`)
2. Create an event on Open Collective under your organisation
3. Edit your Dandelion event and enter the Open Collective event slug under Everything else

Ticket buyers will then see a 'Pay with Open Collective' option at checkout.

## Get email notifications of orders

Make sure the 'Send email notifications of orders' checkbox is checked in the first tab 'Basics' when creating/editing your event.

## Track how people discovered the event

Add `?via=` to the end of your event URL and you will see the result on the Orders page e.g. [https://dandelion.events/e123f?via=may-newsletter](https://dandelion.events/e123f?via=may-newsletter)

## Checking people in

Click the event dropdown and go to the Tickets page for the event. There you can find a check-in toggle for each ticket.

You can also access a check-in scanner by clicking the event dropdown and selecting 'Check-in scanner'. The scanner works well on mobile.

There you can also find a link you can share with assistants which allows them to check people in, without assistants gaining full admin access to the event.

## Adding event facilitators

Go to your event (the main page, not the settings page), click the plus icon next to Facilitators and search for the desired facilitator by name.

## Adding co-hosts

Go to your event (the main page, not the settings page), click the plus icon next to Hosted by and search for the desired organisation by name.

## Emailing attendees

- Click the event dropdown, select Mailer, and click New message.
- Once you've saved the message, you will have the option to send it.

You can also copy email addresses of attendees into your own email app from the Orders or Tickets pages.

## Recurring events/Events across several dates

You have two options here:

1. **Use a single event with multiple Ticket Groups:** Create a single event with the start date as the start date of the first event in the series and the end date as the end date of the last event in the series; then use Ticket Groups to list the different dates ([example here](/events/630e122b1fb42b0010b5d792)).
<br /> 
<br /> 
Ticket groups are created on the Tickets tab when editing your event. To assign tickets to new ticket groups, save the event then return to the Tickets tab.

2. **Create multiple events under a single Activity:** Create an Activity under your Organisation (see the [Organisations](/docs/organisations) page for details on how to do this), and then create multiple events under this activity. Share the link to the Activity for people to view all available dates.

(If the events are the same/very similar, you can create the first event, then duplicate it for all the dates the event occurs by selecting 'Duplicate event' in the event dropdown of the initial event.)

## Cancelling/deleting an event

Click the event dropdown, and select 'Delete event'.

## Where did my secret/locked event go?

You can see all events under an organisation (including events marked secret or locked) by clicking the organisation dropdown and going to **Event stats**.

## Reminders

Dandelion sends event attendees a reminder email the day before the start of the event. You can customise the reminder in your organisation or event settings.

## Feedback

Attendees receive an email with a request for feedback on or shortly after the event end time.

You can resend these emails by going to the Orders page for your event and clicking 'Resend feedback email' next to an order.

Alternatively, attendees can provide feedback by logging in to Dandelion, going to the event page and clicking 'Give feedback'.

## Event recordings

After a scheduled event has finished, you can sell or give access to a recording of it. The event stays tied to its original date; buyers see that they are getting access to a recording of that session.

- **Save the event with a start and end time** and run it as usual.
- Once the event is **in the past**, edit it again: a **Recording** tab appears. Open it and add to **Extra info for order confirmation email**—usually the link to the recording (Vimeo, YouTube, etc.) and any password or viewing instructions. This content is included in the order confirmation email sent to people who book from that point on.
- Optionally, further customise the **Order confirmation email for the recording of the event** in the **Emails** tab.

Recordings are distinct from **evergreen/on-demand** events, which never had a fixed date (see below).

## Evergreen (on-demand) events

Evergreen events are for selling access to something that has **no fixed start time, end time, or location**—for example an on-demand course or pre-recorded content.

- When creating or editing an event, use the link **Mark as evergreen/on-demand, with no dates or location** on the **Basics** tab. That reveals the evergreen option; once enabled, date, time, and location fields are hidden.
- Enter the link to the video/course etc on the **Description and confirmation** tab under **Extra info for order confirmation email** (similar to where you'd enter a Zoom link for a live, online event). 
- In listings and carousels, evergreen events show first, as **On-demand** instead of under a date.
- **Reminder emails** and **automated feedback request** emails are not sent for evergreen events. You can still use the Mailer to email attendees manually.
- **PDF tickets** are not issued, and the order confirmation refers to access as a **link** rather than tickets.

Evergreen events are different from **recordings of dated live events** (see above): recordings keep the original event date for context.

## Displaying feedback publicly

Click the dropdown for your event (/activity/local group/organisation), and select Feedback.

- **If a piece of feedback has a 'Show an extract' link,** you can click the link and then copy-paste the extract you want to show publicly into the box that appears.
- **If a piece of feedback doesn't have a 'Show an extract' link,** it means the person that submitted the feedback doesn't want it shown publicly.

## Discount codes

To create a discount code, click the dropdown for your event (or organisation, activity or local group if you want the discount code to apply across several events), and select 'Discount codes'.

## Waitlists

If your event sells out, a waitlist will be activated automatically. You can view people on the waitlist by selecting Waitlist in the event dropdown.

Dandelion automatically emails people on your waitlist if tickets become available again (either by you releasing more tickets, cancelling existing orders, or someone marking a ticket for resale with resales enabled).

You can email your waitlist via Dandelion by going to Mailer in the event dropdown, creating a new message and selecting the waitlist under the To field. Alternatively, you can simply copy and paste the email addresses from the waitlist page into your own email app.

## Fees and payouts

Dandelion does not take any money from ticket sales. Your chosen payment processor, however, likely charges a fee. Read more on:

- [Stripe fees](https://stripe.com/gb/pricing) and [Stripe payout times](https://support.stripe.com/questions/common-questions-about-payout-schedules?locale=en-GB) (You may be able to change from weekly payouts to daily payouts [here](https://dashboard.stripe.com/settings/payouts))
- [GoCardless fees](https://gocardless.com/pricing/)
- [Open Collective fees](https://opencollective.com/)

Alternatively, you can accept completely fee-free crypto payments via Gnosis, Celo, Optimism or Base.

## About the suggested donation

Dandelion operates on a donation/gift economy basis. We ask for donations from organisations, and from ticket purchasers at checkout.

**From organisations:** We ask for a donation of 1% of ticket sales. (If an event has no ticket types listed and is simply an advertisement for an event where tickets are sold elsewhere, we ask for a fixed £25 promotion fee.) Click your organisation dropdown and select Contribute to make a contribution.

**From ticket purchasers at checkout:** By default, donations from ticket purchasers at checkout go to Dandelion. However, if your organisation meets the suggested donation of 1% of ticket sales, we pass on future donations to your organisation instead.

The easiest way to ensure that donations always go to your organisation is to enable auto top-up on the Contribute page.

## Transferring tickets

**Event attendees:** Log in to Dandelion, go to the event page, click 'Edit ticketholders' and enter the name and email address of the person you gifted/sold your ticket to.

The original ticket PDF will still work, so you can simply forward it to the new ticketholder. However, if it's important that the PDF is reissued under the new name, you can get in touch with the event organiser and ask them to 'Resend single ticket' following the instructions below.

**Event organisers that have received a request to transfer a ticket:** Click the event dropdown, go to the Tickets page, and select 'Change name or email' in the Actions menu for the ticket(s).

If you want to resend the ticket PDF to the new email address, after entering the new email, select 'Resend single ticket' in the Actions menu.

## Ticket resales

The ticket resale feature allows event attendees to resell their tickets through the event page. (Technically, what happens is that the original ticket is refunded, and a new ticket is issued to the new buyer.)

Check 'enable resales' under 'Everything else' when editing an event to enable resales.

Attendees mark a ticket for resale by logging in to Dandelion, visiting the event page and selecting 'Mark for resale' next to a ticket.

This makes one more of that ticket type available. If someone then purchases a ticket of this type, the original ticketholder gets a refund, the new buyer gets a fresh ticket, and everyone gets an email notification.

## Gating events with an application form

You can make it so people must first be accepted to an Activity before being able to purchase tickets to events in the activity.

Click your organisation dropdown and select 'Activities' then 'Create an activity'. Under 'Access', select 'People must apply to join' and enter some application questions (answers in textboxes).

Edit your event(s) and assign them to this new activity. Now, people will have to apply and be accepted to the activity before they can purchase tickets to the event(s).

You'll be notified via email when people apply.

## Event boosts

Dandelion has a 'boosted event' slot at the top of the event listings. If you'd like your event to show there, you can boost your event from the **Boosts** page in the event admin menu.

- Boosts are bought in whole-hour blocks.
- You choose a start time, a number of hours, and an amount per hour.
- Overlapping boosts for the same event stack together.

An event's share of the boost pool corresponds to the probability of the event being shown in the boost slot at the top of the unfiltered public events listing (the probability can be higher for filtered listings where the number of relevant events is smaller).

For example, if during one hour:

'Breathwork Journey' tagged 'breathwork' is boosted for £2<br />
'Day Rave' tagged 'rave' is boosted for £8

Then the probability that 'Breathwork Journey' will be shown in the boosted slot when someone views the unfiltered public events listing is 2/(2+8) = 20%.

The probability that 'Breathwork Journey' will be shown in the boosted slot when someone views the public events listings, filtered for the tag 'breathwork' is 100% (as it's the only boosted event that matches the filters).

Likewise, the probability that 'Day Rave' will be shown in the boosted slot when someone views the public events listings, filtered for the tag 'rave' is 100%.

## Using automated revenue sharing

Dandelion has a unique revenue sharing feature allowing organisations to share ticket revenue with their facilitators at the time of purchase. Please [contact us](mailto:contact@dandelion.events) if you'd like to try it.

## What's the difference between an 'abundant' and 'standard' ticket?

Typically, nothing. Some organisations list the same ticket at different prices simply to give those who can afford to contribute more, an opportunity to do so.

## Embedding event listings

Embed an [iframe](https://www.techtarget.com/whatis/definition/IFrame-Inline-Frame) like this, replacing `the-psychedelic-society` with your organisation's slug:

```html
<iframe style="overflow: scroll; border: 0; width:100%; height: 100vh;" class="dandelion-auto-height"  src="https://dandelion.events/o/the-psychedelic-society/events?minimal=1"></iframe>
```

You can also experiment with the parameters `hide_featured_title`, `no_search`, `no_view_options`, `no_listings` and `first_carousel_only` e.g. `?minimal=1&hide_featured_title=1&no_search=1&no_view_options=1&no_listings=1&first_carousel_only=1`

Put this in your head to set the iframe to the correct height:

```html
<script src="//code.jquery.com/jquery-latest.js"></script>
<script src="//cdnjs.cloudflare.com/ajax/libs/iframe-resizer/4.2.10/iframeResizer.min.js"></script>
<script>
  $(function () {
    $('.dandelion-auto-height').iFrameResize({log: true, checkOrigin: false, heightCalculationMethod : 'taggedElement'})
  })
</script>
```

## Embedding ticket forms

Embed an iframe like this, replacing `https://dandelion.events/e/my-event` with your event URL. The `ticket_form_only` query parameter limits the embed to the ticket form:

```html
<iframe style="overflow: scroll; border: 0; width:100%; height: 100vh" class="dandelion-auto-height" src="https://dandelion.events/e/my-event?ticket_form_only=1"></iframe>
```

Use the code in the second half of the previous section to set the iframe to the correct height.
