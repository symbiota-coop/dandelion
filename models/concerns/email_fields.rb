module EmailFields
  extend ActiveSupport::Concern

  MAGIC_TAGS = %w[firstname lastname fullname event_name event_link event_when event_location event_url at_event_location_if_not_online organisation_name ticket_or_tickets tickets_are description_elements key_information_again].freeze
  RECIPIENT_TAGS = %w[firstname lastname fullname event_when ticket_or_tickets tickets_are description_elements].freeze

  def self.recipient_variables(event:, account:, orders: [])
    recipient_tag_values(event: event, account: account, orders: orders)
      .merge('token' => account&.sign_in_token, 'id' => account&.id&.to_s)
  end

  def self.replace_recipient_variables(text, variables)
    variables.reduce(text) do |html, (key, value)|
      html.gsub("%recipient.#{key}%", value.to_s)
    end
  end

  def self.replace_magic_tags(text, event:, account: nil, orders: [], recipient_variables: false, event_name: event.name, plain_text: false)
    html = text.to_s

    if recipient_variables
      RECIPIENT_TAGS.each { |key| html = html.gsub("[#{key}]", "%recipient.#{key}%") }
    else
      recipient_tag_values(event: event, account: account, orders: orders).each do |key, value|
        html = html.gsub("[#{key}]", value.to_s)
      end
    end

    html = html
           .gsub('[event_name]', event_name)
           .gsub('[organisation_name]', event.organisation.name)
           .gsub('[event_location]', event.location.to_s)
           .gsub('[event_url]', "#{ENV['BASE_URI']}/e/#{event.slug}")
           .gsub(' [at_event_location_if_not_online]', event.online? ? '' : " at #{event.location}")
           .gsub('[at_event_location_if_not_online]', event.online? ? '' : "at #{event.location}")
           .gsub('[event_link]', "<a href='#{ENV['BASE_URI']}/e/#{event.slug}'>#{event.name}</a>")
           .gsub('[key_information_again]', event.extra_info_for_ticket_email ? "<p>Here's the key information again for your convenience:</p><hr><p>#{event.extra_info_for_ticket_email}</p>" : '')

    if plain_text
      Premailer.new(html, with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8')
                .to_plain_text
                .squish
    else
      html
    end
  end

  def self.recipient_tag_values(event:, account:, orders: [])
    values = {
      'firstname' => account&.firstname || 'there',
      'lastname' => account&.lastname || '',
      'fullname' => account&.name.to_s,
      'event_when' => event.when_details(account.try(:time_zone)) || ''
    }

    if orders.present?
      ticket_count = orders.sum { |o| o.tickets.length }
      values['ticket_or_tickets'] = ticket_count == 1 ? 'Ticket' : 'Tickets'
      values['tickets_are'] = ticket_count == 1 ? 'ticket is' : 'tickets are'
      values['description_elements'] = orders.flat_map(&:description_elements).join(', ')
    else
      values['ticket_or_tickets'] = ''
      values['tickets_are'] = ''
      values['description_elements'] = ''
    end

    values
  end

  included do
    field :ticket_email_title, type: String
    field :ticket_email_greeting, type: String
    field :recording_email_title, type: String
    field :recording_email_greeting, type: String
    field :reminder_email_title, type: String
    field :reminder_email_body, type: String
    field :feedback_email_title, type: String
    field :feedback_email_body, type: String
  end

  class_methods do
    def email_human_attribute_names
      {
        ticket_email_title: 'Order confirmation email subject',
        ticket_email_greeting: 'Order confirmation email greeting',
        recording_email_title: 'Order confirmation email subject for recordings of past events',
        recording_email_greeting: 'Order confirmation email greeting for recordings of past events',
        reminder_email_title: 'Reminder email subject',
        reminder_email_body: 'Reminder email body',
        feedback_email_title: 'Feedback request email subject',
        feedback_email_body: 'Feedback request email body'
      }
    end

    def email_hints
      {
        ticket_email_title: 'Custom subject line for the order confirmation email.',
        ticket_email_greeting: 'Custom greeting for the order confirmation email.',
        recording_email_title: 'Custom subject line for the order confirmation email for recordings of past events.',
        recording_email_greeting: 'Custom greeting for the order confirmation email for recordings of past events.',
        reminder_email_title: 'Custom subject line for the reminder email.',
        reminder_email_body: 'Custom body for the reminder email.',
        feedback_email_title: 'Custom subject line for the feedback request email.',
        feedback_email_body: 'Custom body for the feedback request email. If you want attendees to be able to leave feedback on Dandelion, include the magic tag <code>[feedback_url]</code>, which we replace with a real URL unique to each attendee.'
      }
    end
  end
end
