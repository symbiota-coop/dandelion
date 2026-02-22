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

## Get email notifications of orders

Make sure the 'Send email notifications of orders' checkbox is checked in the first tab 'Basics' when creating/editing your event.

## Track how people discovered the event

Add ?via= to the end of your event URL and you will see the result on the Orders page e.g. [https://dandelion.events/e123f?via=may-newsletter](https://dandelion.events/e123f?via=may-newsletter)

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
- [Coinbase Commerce fees](https://help.coinbase.com/en/commerce/getting-started/fees)
- [Open Collective fees](https://opencollective.com/)

Alternatively, you can accept completely fee-free crypto payments via Gnosis, Celo, Optimism or Base.

## About the suggested donation

Dandelion operates on a donation/gift economy basis. We ask for donations from organisations, and from ticket purchasers at checkout.

**From organisations:** We ask for a donation of 1% of ticket sales. (If an event has no ticket types listed and is simply an advertisement for an event where tickets are sold elsewhere, we ask for a fixed £25 promotion fee.) Click your organisation dropdown and select Contribute to make a contribution.

**From ticket purchasers at checkout:** By default, donations from ticket purchasers at checkout go to Dandelion. However, if your organisation meets the suggested donation of 1% of ticket sales, we pass on future donations to the organisation instead.

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

## Using automated revenue sharing

Dandelion has a unique revenue sharing feature allowing organisations to share ticket revenue with their facilitators at the time of purchase. Please [contact us](mailto:contact@dandelion.events) if you'd like to try it.

## What's the difference between an 'abundant' and 'standard' ticket?

Typically, nothing. Some organisations list the same ticket at different prices simply to give those than can afford to contribute more, an opportunity to do so.

## Embedding event listings

Embed an [iframe](https://www.techtarget.com/whatis/definition/IFrame-Inline-Frame) like this, replacing the-psychedelic-society with your organisation's slug:

```html
<iframe style="overflow: scroll; border: 0; width:100%; height: 100vh;" class="dandelion-auto-height"  src="https://dandelion.events/o/the-psychedelic-society/events?minimal=1"></iframe>
```

You can also experiment with the parameters hide_featured_title, no_search, no_view_options, no_listings and first_carousel_only e.g. ?minimal=1&hide_featured_title=1&no_search=1&no_view_options=1&no_listings=1&first_carousel_only=1

Put this in your head to set the iframe to the correct height:

```html
<script src="//code.jquery.com/jquery-latest.js"></script>
<script src="//cdnjs.cloudflare.com/ajax/libs/iframe-resizer/4.2.1/iframeResizer.min.js"></script>
<script>
  $(function () {
    $('.dandelion-auto-height').iFrameResize({log: true, checkOrigin: false, heightCalculationMethod : 'taggedElement'})
  })
</script>
```

## Embedding ticket forms

Embed an iframe like this, replacing https://dandelion.events/e/my-event with your event URL:

```html
<iframe style="overflow: scroll; border: 0; width:100%; height: 100vh" class="dandelion-auto-height" src="https://dandelion.events/e/my-event?ticket_form_only=1"></iframe>
```

Use the code in the second half of the previous section to set the iframe to the correct height.
