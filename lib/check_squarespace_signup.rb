module CheckSquarespaceSignup
  def self.check
    Account.find_by(email: ENV['SQUARESPACE_EMAIL']).try(:destroy)

    f = Ferrum::Browser.new
    f.go_to(ENV['SQUARESPACE_URL'])
    f.css('form input')[0].focus.type(ENV['SQUARESPACE_NAME'])
    f.css('form input')[1].focus.type(ENV['SQUARESPACE_EMAIL'])
    f.execute("document.getElementById('#{f.css('form input')[0]['id']}').scrollIntoView()")
    10.times do
      f.at_css('form button').click
      sleep 1
    end
    organisation = Organisation.find_by(slug: ENV['SQUARESPACE_ORGANISATION_SLUG'])
    sleep 10
    raise "Squarespace: Account not created for #{ENV['SQUARESPACE_EMAIL']}" unless (account = Account.find_by(email: ENV['SQUARESPACE_EMAIL'])) && account.organisationships.find_by(organisation: organisation)
  end
end
