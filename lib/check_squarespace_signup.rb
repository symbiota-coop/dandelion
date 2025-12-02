module CheckSquarespaceSignup
  def self.check
    email = ENV['SQUARESPACE_EMAIL']
    organisation_slug = ENV['SQUARESPACE_ORGANISATION_SLUG']
    
    puts "Starting Squarespace signup check for #{email}"
    
    # Clean up existing account
    existing_account = Account.find_by(email: email)
    if existing_account
      puts "Removing existing account for #{email}"
      existing_account.destroy
    end

    # Verify organisation exists
    organisation = Organisation.find_by(slug: organisation_slug)
    raise "Organisation with slug '#{organisation_slug}' not found" unless organisation
    puts "Found organisation: #{organisation.name}"

    browser = Ferrum::Browser.new
    begin
      puts "Navigating to #{ENV['SQUARESPACE_URL']}"
      browser.go_to(ENV['SQUARESPACE_URL'])
      
      # Fill out form
      form_inputs = browser.css('form input')
      raise "Expected form inputs not found on page" if form_inputs.length < 2
      
      puts "Filling out signup form"
      form_inputs[0].focus.type(ENV['SQUARESPACE_NAME'])
      form_inputs[1].focus.type(email)
      browser.execute("document.getElementById('#{form_inputs[0]['id']}').scrollIntoView()")
      
      # Submit form with retry logic
      puts "Submitting form (with retries)"
      form_submitted = false
      10.times do |i|
        puts "Form submission attempt #{i + 1}"
        browser.at_css('form button').click
        sleep 1
        
        # Check if form was submitted (you may need to adjust this based on actual behavior)
        current_url = browser.current_url
        if current_url != ENV['SQUARESPACE_URL']
          puts "Form appears to have been submitted (URL changed to: #{current_url})"
          form_submitted = true
          break
        end
      end
      
      puts "Waiting for account creation (with polling)..."
      
      # Poll for account creation with exponential backoff
      max_attempts = 12
      attempt = 0
      account = nil
      
      while attempt < max_attempts
        attempt += 1
        wait_time = [2 ** attempt, 30].min # Exponential backoff capped at 30 seconds
        
        puts "Checking for account creation (attempt #{attempt}/#{max_attempts}, waiting #{wait_time}s)"
        sleep wait_time
        
        account = Account.find_by(email: email)
        if account
          puts "Account found for #{email}"
          organisationship = account.organisationships.find_by(organisation: organisation)
          if organisationship
            puts "Account successfully associated with organisation #{organisation.name}"
            return account
          else
            puts "Account found but not yet associated with organisation, continuing to wait..."
          end
        else
          puts "Account not yet created, continuing to wait..."
        end
      end
      
      # Final check and detailed error message
      account = Account.find_by(email: email)
      if account
        organisationship = account.organisationships.find_by(organisation: organisation)
        if organisationship
          puts "Account successfully created and associated"
          return account
        else
          available_orgs = account.organisationships.includes(:organisation).map { |os| os.organisation.name }
          raise "Squarespace: Account created for #{email} but not associated with organisation '#{organisation.name}'. Available organisations: #{available_orgs.join(', ')}"
        end
      else
        raise "Squarespace: Account not created for #{email} after #{max_attempts} attempts. Form submitted: #{form_submitted}. Please check Squarespace configuration and ensure the signup process is working correctly."
      end
      
    rescue => e
      puts "Error during Squarespace signup check: #{e.message}"
      puts "Current URL: #{browser.current_url rescue 'unknown'}"
      raise e
    ensure
      browser.quit if browser # Clean up Chrome temp files
    end
  end
end
