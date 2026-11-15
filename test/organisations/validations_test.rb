require_relative '../test_config'

# What an organisation's settings may be set to: its order reward, Mailgun details, event image size and theme colour.
# Called on the model, as nobody is on the other end. Checked with valid?, not saved, so nothing reaches Mailgun
class OrganisationValidationsTest < ActiveSupport::TestCase
  MAILGUN = { mailgun_domain: 'mg.example.com', mailgun_api_key: 'key-123', mailgun_region: 'EU' }.freeze

  def organisation_with(attrs)
    Organisation.find(@organisation.id).tap { |organisation| organisation.assign_attributes(attrs) }
  end

  def assert_setting_refused(attrs, attribute, message)
    organisation = organisation_with(attrs)
    refute organisation.valid?, attrs.inspect
    assert_includes organisation.errors[attribute], message, attrs.inspect
  end

  def assert_setting_allowed(attrs)
    organisation = organisation_with(attrs)
    assert organisation.valid?, "#{attrs.inspect}: #{organisation.errors.full_messages.to_sentence}"
  end

  test 'the order reward is from 1% to 100%' do
    create_organisation
    [0, 101, -5].each { |percentage| assert_setting_refused({ affiliate_credit_percentage: percentage }, :affiliate_credit_percentage, 'must be between 1 and 100') }
    [1, 100, nil].each { |percentage| assert_setting_allowed(affiliate_credit_percentage: percentage) }
  end

  test "the Mailgun domain isn't a sandbox domain" do
    create_organisation
    assert_setting_refused(MAILGUN.merge(mailgun_domain: 'sandbox123abc.mailgun.org'), :mailgun_domain, 'must not be a sandbox domain')
    assert_setting_allowed(MAILGUN)
    # Only Mailgun's own sandbox domains
    assert_setting_allowed(MAILGUN.merge(mailgun_domain: 'sandbox.example.com'))
  end

  test "the Mailgun domain, API key and region are given together" do
    create_organisation
    message = 'must be provided if other Mailgun details have been provided'
    MAILGUN.each_key do |missing|
      assert_setting_refused(MAILGUN.merge(missing => nil), missing, message)
      # Only the missing one is blamed
      organisation = organisation_with(MAILGUN.merge(missing => nil))
      organisation.valid?
      (MAILGUN.keys - [missing]).each { |given| assert_empty organisation.errors[given], "#{given} given, #{missing} missing" }
    end
    assert_setting_allowed(MAILGUN)
    assert_setting_allowed(MAILGUN.transform_values { nil })
  end

  test 'a required event image width and height are greater than 0' do
    create_organisation
    %i[event_image_required_width event_image_required_height].each do |attribute|
      [0, -1].each { |pixels| assert_setting_refused({ attribute => pixels }, attribute, 'must be greater than 0') }
      [1, nil].each { |pixels| assert_setting_allowed(attribute => pixels) }
    end
    assert_setting_allowed(event_image_required_width: 1200, event_image_required_height: 630)
  end

  test 'the theme colour is a hex colour, stored with its #' do
    create_organisation
    ['#12345', '#1234567', 'red', '#GGGGGG', '##ABCDEF'].each do |colour|
      assert_setting_refused({ theme_color: colour }, :theme_color, 'must be a valid hex color (e.g. #ABCDEF)')
    end
    { '#ABCDEF' => '#ABCDEF', 'abcdef' => '#abcdef', '#00af5e' => '#00af5e' }.each do |colour, stored|
      organisation = organisation_with(theme_color: colour)
      assert organisation.save, organisation.errors.full_messages.to_sentence
      assert_equal stored, Organisation.find(@organisation.id).theme_color
    end
  end
end
