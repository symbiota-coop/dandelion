class Delayed::Job
  class RunError < StandardError; end

  after_create do
    if handler.include?(':send_pmail')
      mg_client = Mailgun::Client.new ENV['MAILGUN_API_KEY'], 'api.eu.mailgun.net'
      batch_message = Mailgun::BatchMessage.new(mg_client, 'notifications.dandelion.earth')

      content = handler.gsub("\n", '<br />')
      batch_message.from 'Dandelion <notifications@dandelion.earth>'
      batch_message.subject 'Sending Pmail'
      batch_message.body_html Premailer.new(ERB.new(File.read(Padrino.root('app/views/layouts/email.erb'))).result(binding), with_html_string: true, adapter: 'nokogiri', input_encoding: 'UTF-8').to_inline_css

      Account.and(admin: true).each do |account|
        batch_message.add_recipient(:to, account.email, { 'firstname' => (account.firstname || 'there'), 'token' => account.sign_in_token, 'id' => account.id.to_s })
      end

      batch_message.finalize if ENV['MAILGUN_API_KEY']
    end
  end

  after_destroy do
    if last_error
      begin
        raise Delayed::Job::RunError, last_error.split("\n").first
      rescue StandardError => e
        Airbrake.notify(e, id: YAML.load(handler)['attributes']['_id'].to_s, last_error: last_error.split("\n"))
      end
    end
  end
end
