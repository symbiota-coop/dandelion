module EventDuplication
  extend ActiveSupport::Concern

  def duplicate!(account)
    event = Event.create!(
      duplicate: true,
      name: name,
      start_time: start_time,
      end_time: end_time,
      currency: currency,
      location: location,
      image: image,
      video: video,
      description: description,
      email: email,
      feedback_questions: feedback_questions,
      suggested_donation: suggested_donation,
      minimum_donation: minimum_donation,
      affiliate_credit_percentage: affiliate_credit_percentage,
      capacity: capacity,
      revenue_share_to_revenue_sharer: revenue_share_to_revenue_sharer,
      hide_attendees: hide_attendees,
      hide_discussion: hide_discussion,
      refund_deleted_orders: refund_deleted_orders,
      monthly_donors_only: monthly_donors_only,
      no_discounts: no_discounts,
      extra_info_for_ticket_email: extra_info_for_ticket_email,
      extra_info_for_recording_email: extra_info_for_recording_email,
      zoom_party: zoom_party,
      show_emails: show_emails,
      include_in_parent: include_in_parent,
      opt_in_organisation: opt_in_organisation,
      opt_in_facilitator: opt_in_facilitator,
      locked: true,
      secret: secret,
      account: account,
      last_saved_by: account,
      organisation: organisation,
      activity: activity,
      local_group: local_group,
      coordinator: coordinator,
      revenue_sharer: revenue_sharer,
      organiser: (organiser || account unless revenue_sharer),
      tag_names: event_tags.pluck(:name).join(','),
      add_a_donation_to: add_a_donation_to,
      donation_text: donation_text,
      carousel_text: carousel_text,
      select_tickets_intro: select_tickets_intro,
      select_tickets_outro: select_tickets_outro,
      select_tickets_title: select_tickets_title,
      ask_hear_about: ask_hear_about,
      time_zone: time_zone,
      questions: questions,
      redirect_url: redirect_url,
      purchase_url: purchase_url
    )
    event_tags.each do |event_tag|
      event.event_tagships.create(
        event_tag: event_tag
      )
    end
    event_facilitations.each do |event_facilitation|
      event.event_facilitations.create(
        account: event_facilitation.account
      )
    end
    cohostships.each do |cohostship|
      event.cohostships.create(
        organisation: cohostship.organisation,
        image: cohostship.image,
        video: cohostship.video
      )
    end
    ticket_groups.each do |ticket_group|
      event.ticket_groups.create(
        name: ticket_group.name,
        capacity: ticket_group.capacity
      )
    end
    ticket_types.each do |ticket_type|
      event.ticket_types.create(
        name: ticket_type.name,
        description: ticket_type.description,
        price: ticket_type.price,
        range_min: ticket_type.range_min,
        range_max: ticket_type.range_max,
        quantity: ticket_type.quantity,
        hidden: ticket_type.hidden,
        order: ticket_type.order,
        max_quantity_per_transaction: ticket_type.max_quantity_per_transaction,
        sales_end: ticket_type.sales_end,
        ticket_group: (event.ticket_groups.find_by(name: ticket_type.ticket_group.name) if ticket_type.ticket_group)
      )
    end
    event
  end
end
