module EmailFields
  extend ActiveSupport::Concern

  def self.magic_tags(tags)
    "Magic tags: #{tags.map { |t| "[#{t}]" }.join(', ')}"
  end

  ORDER_CONFIRMATION_SUBJECT_PLACEHOLDERS = %w[ticket_or_tickets event_name].freeze
  ORDER_CONFIRMATION_BODY_PLACEHOLDERS = %w[firstname lastname fullname event_name event_when event_location event_url at_event_location_if_not_online tickets_are description_elements].freeze
  REMINDER_SUBJECT_PLACEHOLDERS = %w[event_name].freeze
  REMINDER_BODY_PLACEHOLDERS = %w[firstname event_link key_information_again].freeze
  FEEDBACK_SUBJECT_PLACEHOLDERS = %w[event_name].freeze
  FEEDBACK_BODY_PLACEHOLDERS = %w[firstname event_name feedback_url organisation_name].freeze

  included do
    field :ticket_email_title, type: String
    field :ticket_email_greeting, type: String
    field :recording_email_title, type: String
    field :recording_email_greeting, type: String
    field :reminder_email_title, type: String
    field :reminder_email_body, type: String
    field :feedback_email_title, type: String
    field :feedback_email_body, type: String

    before_validation do
      errors.add(:feedback_email_body, 'must contain [feedback_url]') if feedback_email_body && !feedback_email_body.include?('[feedback_url]')
    end
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
        ticket_email_title: "Custom subject line for the order confirmation email. #{EmailFields.magic_tags(EmailFields::ORDER_CONFIRMATION_SUBJECT_PLACEHOLDERS)}",
        ticket_email_greeting: "Custom greeting for the order confirmation email. #{EmailFields.magic_tags(EmailFields::ORDER_CONFIRMATION_BODY_PLACEHOLDERS)}",
        recording_email_title: "Custom subject line for the order confirmation email for recordings of past events. #{EmailFields.magic_tags(EmailFields::ORDER_CONFIRMATION_SUBJECT_PLACEHOLDERS)}",
        recording_email_greeting: "Custom greeting for the order confirmation email for recordings of past events. #{EmailFields.magic_tags(EmailFields::ORDER_CONFIRMATION_BODY_PLACEHOLDERS)}",
        reminder_email_title: "Custom subject line for the reminder email. #{EmailFields.magic_tags(EmailFields::REMINDER_SUBJECT_PLACEHOLDERS)}",
        reminder_email_body: "Custom body for the reminder email. #{EmailFields.magic_tags(EmailFields::REMINDER_BODY_PLACEHOLDERS)}",
        feedback_email_title: "Custom subject line for the feedback request email. #{EmailFields.magic_tags(EmailFields::FEEDBACK_SUBJECT_PLACEHOLDERS)}",
        feedback_email_body: "Custom body for the feedback request email. #{EmailFields.magic_tags(EmailFields::FEEDBACK_BODY_PLACEHOLDERS)}. You must include [feedback_url] which Dandelion replaces with a real URL unique to each attendee."
      }
    end
  end
end
