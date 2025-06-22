module EmailFields
  extend ActiveSupport::Concern

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
    def email_admin_fields
      {
        ticket_email_title: :text,
        ticket_email_greeting: :text_area,
        recording_email_title: :text,
        recording_email_greeting: :text_area,
        reminder_email_title: :text,
        reminder_email_body: :text_area,
        feedback_email_title: :text,
        feedback_email_body: :text_area
      }
    end

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
        ticket_email_title: 'Custom subject line for the order confirmation email',
        ticket_email_greeting: 'Custom greeting for the order confirmation email',
        recording_email_title: 'Custom subject line for the order confirmation email for recordings of past events',
        recording_email_greeting: 'Custom greeting for the order confirmation email for recordings of past events',
        reminder_email_title: 'Custom subject line for the reminder email',
        reminder_email_body: 'Custom body for the reminder email',
        feedback_email_title: 'Custom subject line for the feedback request email',
        feedback_email_body: 'Custom body for the feedback request email'
      }
    end
  end
end
