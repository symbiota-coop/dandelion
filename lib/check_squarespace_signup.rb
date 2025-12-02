module CheckSquarespaceSignup
  def self.check
    Account.find_by(email: ENV['SQUARESPACE_EMAIL']).try(:destroy)

    browser = Ferrum::Browser.new
    begin
      browser.go_to(ENV['SQUARESPACE_URL'])
      browser.css('form input')[0].focus.type(ENV['SQUARESPACE_NAME'])
      browser.css('form input')[1].focus.type(ENV['SQUARESPACE_EMAIL'])
      browser.execute("document.getElementById('#{browser.css('form input')[0]['id']}').scrollIntoView()")
      10.times do
        browser.at_css('form button').click
        sleep 1
      end
      organisation = Organisation.find_by(slug: ENV['SQUARESPACE_ORGANISATION_SLUG'])
      sleep 10
      raise "Squarespace: Account not created for #{ENV['SQUARESPACE_EMAIL']}" unless (account = Account.find_by(email: ENV['SQUARESPACE_EMAIL'])) && account.organisationships.find_by(organisation: organisation)
    ensure
      browser.quit # Clean up Chrome temp files
    end
  end
end
