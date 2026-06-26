require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")
require 'rack/test'

class IcsKeysTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  def app
    Padrino.application
  end

  def save_screenshot(*); end

  test 'accounts get a separate ics key' do
    account = FactoryBot.create(:account)

    assert account.ics_key.present?
    refute_equal account.api_key, account.ics_key
  end

  test 'ics key grants access to birthdays ics but not birthdays html' do
    account = FactoryBot.create(:account)
    followee = FactoryBot.create(:account, date_of_birth: Date.new(1990, 1, 1))
    Follow.create!(follower: account, followee: followee)

    get "/birthdays.ics?ics_key=#{account.ics_key}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'BEGIN:VCALENDAR'
    assert_includes last_response.body, followee.name

    get "/birthdays?ics_key=#{account.ics_key}"
    assert_equal 302, last_response.status
  end

  test 'ics key grants access to my events ics but not my events html' do
    account = FactoryBot.create(:account)
    organisation = FactoryBot.create(:organisation, account: account)
    event = FactoryBot.create(:event, organisation: organisation, account: account, last_saved_by: account, coordinator: account)

    get "/events/my.ics?ics_key=#{account.ics_key}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'BEGIN:VCALENDAR'
    assert_includes last_response.body, event.name

    get "/events/my?ics_key=#{account.ics_key}"
    assert_equal 302, last_response.status
  end

  test 'ics key grants access to gathering birthdays only for a member' do
    account = FactoryBot.create(:account)
    non_member = FactoryBot.create(:account)
    gathering = FactoryBot.create(:gathering, account: account)

    get "/g/#{gathering.slug}/birthdays.ics?ics_key=#{account.ics_key}"
    assert_equal 200, last_response.status
    assert_includes last_response.body, 'BEGIN:VCALENDAR'

    get "/g/#{gathering.slug}/birthdays.ics?ics_key=#{non_member.ics_key}"
    assert_equal 302, last_response.status
  end
end
