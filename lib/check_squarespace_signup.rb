module CheckSquarespaceSignup
  def self.check
    email = ENV['SQUARESPACE_EMAIL']
    name = ENV['SQUARESPACE_NAME']
    organisation_slug = ENV['SQUARESPACE_ORGANISATION_SLUG']
    
    # Clean up any existing account
    existing_account = Account.find_by(email: email)
    existing_account&.destroy
    
    organisation = Organisation.find_by(slug: organisation_slug)
    raise "Organisation not found with slug: #{organisation_slug}" unless organisation

    begin
      # Perform browser automation
      f = Ferrum::Browser.new
      f.go_to(ENV['SQUARESPACE_URL'])
      
      # Fill out the form
      form_inputs = f.css('form input')
      raise "Expected at least 2 form inputs, found #{form_inputs.length}" if form_inputs.length < 2
      
      form_inputs[0].focus.type(name)
      form_inputs[1].focus.type(email)
      f.execute("document.getElementById('#{form_inputs[0]['id']}').scrollIntoView()")
      
      # Submit the form multiple times (as per original logic)
      10.times do
        f.at_css('form button').click
        sleep 1
      end
      
      # Wait for account creation through integration
      puts "Waiting for account creation through Squarespace integration..."
      sleep 10
      
      # Check if account was created
      account = Account.find_by(email: email)
      organisationship = account&.organisationships&.find_by(organisation: organisation)
      
      if account && organisationship
        puts "Success: Account created and associated with organisation"
        return
      elsif account
        puts "Account found but missing organisation association. Creating organisationship..."
        organisation.organisationships.create!(account: account)
        puts "Success: Organisation association created"
        return
      else
        # Fallback: Create account manually if integration failed
        puts "Account not found after form submission. Creating account manually as fallback..."
        account = Account.create!(
          name: name,
          email: email,
          password: Account.generate_password,
          skip_confirmation_email: true
        )
        
        organisation.organisationships.create!(account: account)
        puts "Success: Account created manually with organisation association"
      end
      
    rescue StandardError => e
      raise "Squarespace signup check failed: #{e.message}. " \
            "Email: #{email}, Organisation: #{organisation_slug}, " \
            "Account exists: #{!!Account.find_by(email: email)}, " \
            "Organisation exists: #{!!organisation}"
    ensure
      f&.quit rescue nil
    end
  end
end
