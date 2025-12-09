require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class NavTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'header nav' do
    @account = FactoryBot.create(:account)
    login_as(@account)
    visit '/'
    hrefs = all('#header .nav a', visible: :all).map { |a| a['href'] }.reject { |a| a == 'javascript:;' }
    hrefs.each do |href|
      next unless href.starts_with?('/')

      puts URI(href).path
      visit href
      assert true
    end
  end

  test 'sidebar nav' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @gathering = FactoryBot.create(:gathering, account: @account)
    login_as(@account)
    visit '/'
    hrefs = all('#sidebar .nav a', visible: :all).map { |a| a['href'] }.reject { |a| a == 'javascript:;' }
    hrefs.each do |href|
      next unless href.starts_with?('/')

      puts URI(href).path
      visit href
      assert true
    end
  end

  test 'organisation nav' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    login_as(@account)
    visit "/o/#{@organisation.slug}"
    hrefs = all('#content .dropdown-menu', visible: :all)[0].all('a', visible: :all).map { |a| a['href'] }.reject { |a| a == 'javascript:;' }
    hrefs.each do |href|
      next unless href.starts_with?('/')

      puts URI(href).path
      visit href
      assert true
    end
  end

  test 'activity nav' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @activity = FactoryBot.create(:activity, organisation: @organisation, account: @account)
    login_as(@account)
    visit "/activities/#{@activity.id}"
    hrefs = all('#content .dropdown-menu', visible: :all)[1].all('a', visible: :all).map { |a| a['href'] }.reject { |a| a == 'javascript:;' }
    hrefs.each do |href|
      next unless href.starts_with?('/')

      puts URI(href).path
      visit href
      assert true
    end
  end

  test 'local group nav' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @local_group = FactoryBot.create(:local_group, organisation: @organisation, account: @account)
    login_as(@account)
    visit "/local_groups/#{@local_group.id}"
    hrefs = all('#content .dropdown-menu', visible: :all)[1].all('a', visible: :all).map { |a| a['href'] }.reject { |a| a == 'javascript:;' }
    hrefs.each do |href|
      next unless href.starts_with?('/')

      puts URI(href).path
      visit href
      assert true
    end
  end

  test 'event nav' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @event = FactoryBot.create(:event, organisation: @organisation, account: @account, last_saved_by: @account)
    login_as(@account)
    visit "/e/#{@event.slug}"
    hrefs = all('#content .dropdown-menu', visible: :all)[1].all('a', visible: :all).map { |a| a['href'] }.reject { |a| a == 'javascript:;' }
    hrefs.each do |href|
      next unless href.starts_with?('/')

      puts URI(href).path
      visit href
      assert true
    end
  end

  test 'gathering nav' do
    @account = FactoryBot.create(:account)
    @gathering = FactoryBot.create(:gathering, account: @account)
    login_as(@account)
    visit "/g/#{@gathering.slug}"
    hrefs = all('#gathering-nav a', visible: :all).map { |a| a['href'] }.reject { |a| a == 'javascript:;' }
    hrefs.each do |href|
      next unless href.starts_with?('/')

      puts URI(href).path
      visit href
      assert true
    end
  end
end
