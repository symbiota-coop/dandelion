module EventFields
  extend ActiveSupport::Concern

  included do
    attr_accessor :prevent_notifications, :update_tag_names, :tag_names, :duplicate

    field :name, type: String
    index({ name: 1 })
    field :slug, type: String
    index({ slug: 1 })
    field :start_time, type: Time
    field :end_time, type: Time
    field :location, type: String
    field :coordinates, type: Array
    field :image_uid, type: String
    field :video_uid, type: String
    field :description, type: String
    index({ description: 1 })
    field :email, type: String
    field :facebook_event_url, type: String
    field :feedback_questions, type: String
    field :suggested_donation, type: Float
    field :minimum_donation, type: Float
    field :capacity, type: Integer
    field :affiliate_credit_percentage, type: Integer
    field :extra_info_for_ticket_email, type: String
    field :extra_info_for_recording_email, type: String
    field :notes, type: String
    field :redirect_url, type: String
    field :purchase_url, type: String
    field :currency, type: String
    field :facebook_pixel_id, type: String
    field :time_zone, type: String
    field :questions, type: String
    field :add_a_donation_to, type: String
    field :donation_text, type: String
    field :carousel_text, type: String
    field :select_tickets_intro, type: String
    field :select_tickets_outro, type: String
    field :select_tickets_title, type: String
    field :rsvp_button_text, type: String
    field :fixed_contribution_gbp, type: Float
    field :cap_gbp, type: Float
    field :oc_slug, type: String
    field :ticket_email_greeting, type: String
    field :ticket_email_title, type: String
    field :ai_tagged, type: Mongoid::Boolean
    field :boosted, type: Mongoid::Boolean
    field :event_tags_joined, type: String

    field :revenue_share_to_revenue_sharer, type: Integer
    field :profit_share_to_organiser, type: Integer
    field :profit_share_to_coordinator, type: Integer
    field :profit_share_to_category_steward, type: Integer
    field :profit_share_to_social_media, type: Integer
    field :stripe_revenue_adjustment, type: Float

    %w[no_discounts hide_attendees hide_discussion refund_deleted_orders monthly_donors_only locked secret zoom_party show_emails include_in_parent featured opt_in_organisation opt_in_facilitator hide_few_left hide_organisation_footer ask_hear_about send_order_notifications raw_description prevent_reminders trending hide_from_trending hide_from_carousels no_tickets_pdf half_width_images enable_resales donations_to_organisation browsable].each do |b|
      field b.to_sym, type: Mongoid::Boolean
      index({ b.to_s => 1 })
    end
  end

  class_methods do
    def admin_fields
      {
        summary: { type: :text, index: false, edit: false },
        name: { type: :text, full: true },
        slug: :slug,
        start_time: :datetime,
        end_time: :datetime,
        location: :text,
        add_a_donation_to: :text,
        donation_text: :text,
        carousel_text: :text,
        select_tickets_intro: :text,
        select_tickets_outro: :text,
        select_tickets_title: :text,
        rsvp_button_text: :text,
        image: :image,
        video: :file,
        description: :wysiwyg,
        email: :email,
        facebook_event_url: :url,
        feedback_questions: :text_area,
        hide_attendees: :check_box,
        hide_discussion: :check_box,
        refund_deleted_orders: :check_box,
        monthly_donors_only: :check_box,
        no_discounts: :check_box,
        trending: :check_box,
        hide_from_trending: :check_box,
        extra_info_for_ticket_email: :wysiwyg,
        extra_info_for_recording_email: :wysiwyg,
        suggested_donation: :number,
        minimum_donation: :number,
        capacity: :number,
        notes: :text_area,
        redirect_url: :url,
        purchase_url: :url,
        locked: :check_box,
        secret: :check_box,
        hide_few_left: :check_box,
        questions: :text_area,
        zoom_party: :check_box,
        show_emails: :check_box,
        opt_in_organisation: :check_box,
        opt_in_facilitator: :check_box,
        hide_organisation_footer: :check_box,
        send_order_notifications: :check_box,
        raw_description: :check_box,
        donations_to_organisation: :check_box,
        account_id: :lookup,
        organisation_id: :lookup,
        activity_id: :lookup,
        ticket_types: :collection
      }
    end

    def human_attribute_name(attr, options = {})
      {
        description: 'Public event description',
        name: 'Event title',
        slug: 'Short URL',
        email: 'Contact email',
        questions: 'Further questions to ask on the order form',
        facebook_event_url: 'Facebook event URL',
        facebook_pixel_id: 'Facebook Pixel ID',
        show_emails: 'Allow all event admins to view email addresses of attendees',
        opt_in_organisation: 'Allow people to opt in to emails from the host organisation(s)',
        opt_in_facilitator: 'Allow people to opt in to emails from facilitators',
        refund_deleted_orders: 'Refund deleted orders/tickets on Stripe',
        redirect_url: 'Redirect URL after successful payment',
        include_in_parent: 'Include in parent organisation event listings',
        zoom_party: 'Zoom party',
        add_a_donation_to: 'Text beside donation field',
        donation_text: 'Text below donation field',
        start_time: 'Start date/time',
        end_time: 'End date/time',
        extra_info_for_ticket_email: 'Extra info for order confirmation email',
        extra_info_for_recording_email: 'Extra info for order confirmation email',
        purchase_url: 'Ticket purchase URL',
        no_discounts: 'No discounts for monthly donors',
        notes: 'Private notes',
        ask_hear_about: 'Ask people how they heard about the event',
        capacity: 'Total capacity',
        gathering_id: 'Add people that buy tickets to this gathering',
        send_order_notifications: 'Send email notifications of orders',
        prevent_reminders: 'Prevent reminder email',
        oc_slug: 'Open Collective event slug',
        no_tickets_pdf: "Don't include tickets PDF in confirmation email",
        hide_few_left: "Hide 'few tickets left' labels",
        ticket_email_title: 'Order confirmation email subject',
        ticket_email_greeting: 'Order confirmation greeting',
        rsvp_button_text: 'RSVP button'
      }[attr.to_sym] || super
    end

    def new_hints
      {
        slug: 'Lowercase letters, numbers and dashes only (no spaces)',
        image: 'At least 992px wide, and more wide than high',
        start_time: "in &hellip; (your profile's time zone)",
        end_time: "in &hellip; (your profile's time zone)",
        add_a_donation_to: "Text to display beside the 'Add a donation' field (leave blank to use organisation default)",
        oc_slug: 'Event slug for taking payments via Open Collective',
        donation_text: "Text to display below the 'Add a donation' field  (leave blank to use organisation default)",
        carousel_text: 'Text to show when hovering over the event in a carousel',
        select_tickets_title: 'Title of the Select Tickets panel (default: Select tickets)',
        select_tickets_intro: 'Text to show at the top of the Select Tickets panel',
        select_tickets_outro: 'Text to show at the bottom of the Select Tickets panel',
        rsvp_button_text: 'Title of the RSVP button for free tickets',
        ask_hear_about: 'Ask people how they heard about the event on the order form',
        suggested_donation: 'If this is blank, the donation field will not be shown',
        extra_info_for_ticket_email: 'This is the place to enter Zoom links, directions to the venue, etc.',
        extra_info_for_recording_email: 'This is the place to enter the link to the recording.',
        featured: "Feature the event in a carousel on the organisation's events page",
        secret: 'Hide the event from all public listings',
        locked: 'Make the event visible to admins only',
        hide_attendees: 'Hide the public list of attendees (in any case, individuals must opt in)',
        hide_discussion: 'Hide the private discussion for attendees and facilitators',
        hide_from_carousels: 'Hide the event from carousels',
        show_emails: 'Allow all event admins to view attendee emails (by default, only organisation admins see them)',
        opt_in_organisation: 'Allow people to opt in to receive emails from host organisation(s)',
        opt_in_facilitator: "Allow people to opt in to receive emails from any facilitators' personal lists",
        monthly_donors_only: 'Only allow people making a monthly donation to the organisation to purchase tickets',
        no_discounts: "Don't apply usual discounts for monthly donors to the organisation",
        include_in_parent: 'If the event has a local group, show it in the event listings of the parent organisation',
        refund_deleted_orders: 'Refund deleted orders/tickets via Stripe, and all orders if the event is deleted',
        redirect_url: 'Optional. By default people will be shown a thank you page on Dandelion.',
        facebook_pixel_id: 'Your Facebook Pixel ID for tracking sales',
        purchase_url: "URL where people can buy tickets (if you're not selling tickets on Dandelion)",
        capacity: 'Caps the total number of tickets issued across all ticket types. Optional',
        send_order_notifications: 'Send email notifications of orders to event facilitators',
        prevent_reminders: 'Prevent reminder email from being sent before the event',
        stripe_revenue_adjustment: 'Positive or negative adjustment to the revenue reported by Stripe, e.g. +20 or -10',
        enable_resales: 'Allow ticketholders to resell tickets via the event once a ticket type sells out (experimental)',
        hide_few_left: "Hide the 'few tickets left' labels at checkout when tickets are running low",
        hide_organisation_footer: 'Hide the organisation footer in the event confirmation email',
        no_tickets_pdf: 'Skip the PDF attachment in the confirmation email',
        ticket_email_title: 'Custom subject line for the order confirmation email',
        ticket_email_greeting: 'Custom greeting for the order confirmation email'
      }
    end

    def edit_hints
      {}.merge(new_hints)
    end
  end
end
