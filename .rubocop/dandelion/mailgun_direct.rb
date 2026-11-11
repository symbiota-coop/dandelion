module RuboCop
  module Cop
    module Dandelion
      # Send email with `Mailer.deliver`, not a Mailgun::BatchMessage or Mailgun::Client of your own. Mailer is the one
      # place that decides each email's Mailgun domain, sender and when it is sent (production only, or wherever there's
      # an API key), writes attachments to tempfiles it removes, and builds the BatchMessage that
      # EmailHelper::RecipientVariables makes safe and tests record. `lib/mail` is where Mailgun is used directly.
      #
      # @example
      #   # bad
      #   batch_message = Mailgun::BatchMessage.new(Mailgun::Client.new(ENV['MAILGUN_API_KEY'], ENV['MAILGUN_REGION']), ENV['MAILGUN_NOTIFICATIONS_HOST'])
      #
      #   # good
      #   Mailer.deliver(:order, to: event.event_facilitators, subject: "New order for #{event.name}", locals: { order:, event: })
      class MailgunDirect < Base
        MSG = 'Send email with `Mailer.deliver` (lib/mail/mailer.rb), not `Mailgun::%<class>s.new`.'
        RESTRICT_ON_SEND = %i[new].freeze

        def_node_matcher :mailgun_new, '(send (const (const {nil? cbase} :Mailgun) ${:BatchMessage :Client}) :new ...)'

        def on_send(node)
          mailgun_new(node) { |klass| add_offense(node, message: format(MSG, class: klass)) }
        end
      end
    end
  end
end
