module EventSerialization
  extend ActiveSupport::Concern

  class_methods do
    def to_public_json
      with_key_includes.map(&:public_data).to_json
    end

    def to_public_xml
      with_key_includes.map(&:public_data).to_xml(root: 'events')
    end

    def to_public_markdown
      with_key_includes.map(&:public_data).to_markdown
    end
  end

  def to_public_json
    public_data.to_json
  end

  def to_public_xml
    public_data.to_xml(root: 'event')
  end

  def to_public_markdown
    public_data.to_markdown(title: :name, html_keys: %i[description])
  end

  def public_data
    {
      id: id.to_s,
      slug: slug,
      url: "#{ENV['BASE_URI']}/e/#{slug}",
      name: name,
      cohosts: cohostships.map { |cohostship| { name: cohostship.organisation.name, slug: cohostship.organisation.slug } },
      facilitators: event_facilitations.map { |event_facilitation| { name: event_facilitation.account.name, username: event_facilitation.account.username } },
      activity: activity ? { name: activity.name, id: activity_id.to_s } : nil,
      local_group: local_group ? { name: local_group.name, id: local_group_id.to_s } : nil,
      email: email,
      tags: event_tagships.map(&:event_tag_name),
      start_time: start_time,
      end_time: end_time,
      location: location,
      time_zone: time_zone,
      image: image ? image.url : nil,
      description: description
    }
  end

  # Ticket types anyone can buy (hidden ones need their secret link), as listed on the event page
  def public_ticket_types
    ticket_types.and(hidden: false).order('order asc, price desc').map do |ticket_type|
      {
        id: ticket_type.id.to_s,
        name: ticket_type.name,
        description: ticket_type.public_description,
        pricing: if ticket_type.range
                   'range'
                 elsif ticket_type.price
                   'fixed'
                 else
                   'pay_what_you_want'
                 end,
        price: ticket_type.price,
        price_min: ticket_type.range_min,
        price_max: ticket_type.range_max,
        currency: currency,
        available: [ticket_type.number_of_tickets_available_in_single_purchase, 0].max,
        sold_out: ticket_type.sold_out?,
        sales_end: ticket_type.sales_end,
        ticket_group: ticket_type.ticket_group&.name,
        minimum_monthly_donation: ticket_type.minimum_monthly_donation
      }
    end
  end

  # What the checkout form on the event page asks for, so an agent can prepare a booking
  def checkout_requirements
    restrictions = []
    restrictions << 'sales_closed' if sales_closed_due_to_event_end?
    restrictions << 'monthly_donors_only' if monthly_donors_only
    restrictions << 'members_only' if activity && activity.privacy != 'open'

    buyer_fields = [
      { name: 'name', required: true },
      { name: 'email', required: true }
    ]
    buyer_fields << { name: 'phone', required: false, format: 'international, starting with +' } if organisation&.collect_phone?
    buyer_fields += [{ name: 'postcode', required: false }, { name: 'country', required: false }] if organisation&.collect_location
    buyer_fields << { name: 'hear_about', required: false } if ask_hear_about

    opt_ins = []
    opt_ins << { name: 'opt_in_organisation', label: "Get email updates from #{organisation_and_cohosts.map(&:name).to_sentence}" } if opt_in_organisation
    opt_ins << { name: 'opt_in_facilitator', label: "Get email updates from #{event_facilitators.map(&:firstname).to_sentence}" } if opt_in_facilitator && event_facilitators.exists?

    {
      event: { id: id.to_s, slug: slug, name: name, url: "#{ENV['BASE_URI']}/e/#{slug}", start_time: start_time, end_time: end_time, time_zone: time_zone },
      purchasable: restrictions.empty? && !sold_out?,
      restrictions: restrictions,
      agent_bookings: !organisation&.no_agent_bookings,
      currency: currency,
      ticket_types: public_ticket_types,
      buyer_fields: buyer_fields,
      questions: Questions.parse(questions),
      opt_ins: opt_ins,
      terms: {
        text: terms_and_conditions_for_purchase,
        url: terms_and_conditions_url_for_purchase,
        must_accept: terms_acceptance_required?,
        platform_terms_url: "#{ENV['BASE_URI']}/terms",
        organiser: responsible_name
      },
      payment_methods: EventPaymentMethod.all.select { |pm| pm.process && pm.available?(self) }.map { |pm| { name: pm.name, label: pm.button_label(self), agent_checkout: pm.redirect || pm.complimentary } }
    }
  end
end
