module CheckSquarespaceSignup
  def self.check
    Account.find_by(email: ENV['SQUARESPACE_EMAIL']).try(:destroy)

    f = Ferrum::Browser.new
    f.go_to(ENV['SQUARESPACE_URL'])
    
    # Wait for page to load and find form inputs with error handling
    inputs = nil
    5.times do
      inputs = f.css('form input')
      break if inputs.length >= 2
      sleep 2
    end
    
    raise "Squarespace: Could not find required form inputs on page" if inputs.nil? || inputs.length < 2
    
    # Fill form fields with error handling
    name_input = inputs[0]
    email_input = inputs[1]
    
    raise "Squarespace: Name input not found" unless name_input
    raise "Squarespace: Email input not found" unless email_input
    
    name_input.focus.type(ENV['SQUARESPACE_NAME'])
    email_input.focus.type(ENV['SQUARESPACE_EMAIL'])
    f.execute("document.getElementById('#{name_input['id']}').scrollIntoView()")
    
    # Find and click submit button with error handling
    submit_button = f.at_css('form button')
    raise "Squarespace: Submit button not found" unless submit_button
    
    10.times do
      submit_button.click
      sleep 1
    end
    
    organisation = Organisation.find_by(slug: ENV['SQUARESPACE_ORGANISATION_SLUG'])
    sleep 10
    raise "Squarespace: Account not created for #{ENV['SQUARESPACE_EMAIL']}" unless (account = Account.find_by(email: ENV['SQUARESPACE_EMAIL'])) && account.organisationships.find_by(organisation: organisation)
  ensure
    f&.quit
  end
end
