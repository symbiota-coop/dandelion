require File.expand_path(File.dirname(__FILE__) + '/test_config.rb')

class CoreTest < ActiveSupport::TestCase
  include Capybara::DSL

  setup do
    Capybara.reset_sessions!
    Dir[Padrino.root('models', '*')].each { |f| f.split('/').last.split('.').first.camelize.constantize.delete_all }
  end

  teardown do
    save_screenshot unless ENV['CI']
  end

  test 'creating a pmail' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @pmail = FactoryBot.build_stubbed(:pmail)
    login_as(@account)
    visit "/o/#{@organisation.slug}/pmails"
    click_link 'New message'
    fill_in 'Subject', with: @pmail.subject
    execute_script %{$('#pmail_to_option').val('all')}
    click_button 'Save'
    assert page.has_content? 'The mail was saved'
  end

  test 'editing a pmail' do
    @account = FactoryBot.create(:account)
    @organisation = FactoryBot.create(:organisation, account: @account)
    @pmail = FactoryBot.create(:pmail, organisation: @organisation)
    login_as(@account)
    visit "/o/#{@organisation.slug}/pmails"
    click_link 'Edit'
    assert page.has_css? '.CodeMirror'
    execute_script %{easyMDE.value('#{body = FactoryBot.build_stubbed(:pmail).body}')}
    click_button 'Save'
    assert page.has_content? 'The mail was saved'
    visit "/pmails/#{@pmail.id}/preview?organisation_id=#{@organisation.id}"
    assert page.has_content? body
  end
end
