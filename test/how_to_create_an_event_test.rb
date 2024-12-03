require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DandelionTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'how to create an event' do
    @account = FactoryBot.build_stubbed(:account, name: 'Maria Sabina', email: 'maria@symbiota.coop', location: nil)
    @organisation = FactoryBot.build_stubbed(:organisation, name: 'Mystica')
    @event = FactoryBot.build_stubbed(:event, name: 'Introduction to Mystica', start_time: Time.now.tomorrow.change(hour: 19), end_time: Time.now.tomorrow.change(hour: 20), description: 'Join us for an introduction to Mystica!', extra_info_for_ticket_email: 'The Zoom link is https://us06web.zoom.us/j/123456789')
    @ticket_type = FactoryBot.build_stubbed(:ticket_type, name: 'Standard', price_or_range: 10, quantity: 50)
    visit '/'
    narrate %(Hi, I'm going to show you how easy it is to set up an event on Dandelion. Start by clicking 'List an event'.)
    click_link 'List an event'
    narrate %(First you'll need to create an account. Fill in some personal details and click 'Sign up'.), lambda {
      fill_in 'Full name', with: @account.name
      fill_in 'Email', with: @account.email
      fill_in 'Location', with: @account.location
    }
    click_button 'Sign up'
    narrate %(OK, you're in! All events on Dandelion are listed under an organisation. Fill in some details of the organisation and click 'Save and continue'.), lambda {
      fill_in 'Organisation name', with: @organisation.name
    }
    click_button 'Save and continue'
    narrate %(Connect your Stripe account and click 'Update organisation'.)
    sleep 1
    Organisation.first.set(stripe_pk: @organisation.stripe_pk, stripe_sk: @organisation.stripe_sk)
    click_button 'Update organisation'
    narrate %(OK, your organisation is ready! Now let's create an event. Provide an event title, and start and end time.), lambda {
      fill_in 'Event title*', with: @event.name
      execute_script %{$('#event_start_time').val('#{@event.start_time.to_fs(:db_local)}')}
      execute_script %{$('#event_start_time').flatpickr({ altInput: true, altFormat: 'J F Y, H:i', enableTime: true, time_24hr: true })}
      execute_script %{$('#event_end_time').val('#{@event.end_time.to_fs(:db_local)}')}
      execute_script %{$('#event_end_time').flatpickr({ altInput: true, altFormat: 'J F Y, H:i', enableTime: true, time_24hr: true })}
    }
    click_link 'Description and confirmation email'
    narrate %(Click 'Description and confirmation email', and provide an event description and any extra info for the ticket confirmation email.), lambda {
      execute_script %{const field = $('#event_description'); const editorInstance = field.next().find('[contenteditable]')[0].ckeditorInstance; editorInstance.setData('#{@event.description}')}
      execute_script %{const field = $('#event_extra_info_for_ticket_email'); const editorInstance = field.next().find('[contenteditable]')[0].ckeditorInstance; editorInstance.setData('#{@event.extra_info_for_ticket_email}')}
    }
    click_link 'Tickets'
    narrate %(Click 'Tickets', and add some ticket types.), lambda {
      execute_script %{$("a:contains('Add ticket type')").click()}
    }
    narrate %(Fill in the ticket type name, price and quantity.), lambda {
      fill_in 'event_ticket_types_attributes_0_name', with: @ticket_type.name
      fill_in 'event_ticket_types_attributes_0_price_or_range', with: @ticket_type.price_or_range
      fill_in 'event_ticket_types_attributes_0_quantity', with: @ticket_type.quantity
    }
    narrate %(That'll do for now - click the final tab and then 'Create event'.), lambda {
      click_link 'Everything else'
    }
    execute_script %{window.scrollTo(0, document.body.scrollHeight);}
    click_button 'Create event'
    narrate %(You're done!)
    create_video
  end
end
