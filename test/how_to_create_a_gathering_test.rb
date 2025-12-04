require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class DandelionTest < ActiveSupport::TestCase
  include Capybara::DSL

  test 'how to create a gathering' do
    @account1 = FactoryBot.create(:account, name: 'Maria Sabina', email: 'maria@symbiota.coop')
    @account2 = FactoryBot.create(:account, name: 'David Bohm', email: 'david@symbiota.coop')
    @gathering = FactoryBot.build_stubbed(:gathering, name: 'Garden Gathering', slug: 'garden-gathering')
    login_as(@account1)
    click_link 'Gatherings'
    click_link 'All gatherings'
    narrate %(
      Dandelion Gatherings are highly co-created gatherings typically lasting between 2 days and 2 weeks, for 20 to 200 people.
      This feature was originally developed to support camps at European Burning Man events, and has since been used for several standalone microburns, along with online-only unconferences.
      Click 'Create a gathering' to get started.
    )
    within('#sidebar') { click_link 'Create a gathering' }
    narrate %(Enter the name of the gathering.), lambda {
      fill_in 'Name', with: @gathering.name
    }
    click_link 'Joining'
    narrate %(
      Choose from three access modes: Anyone with the link can join, People must apply to join, and Invitation-only.
      Let's go with 'People must apply to join'.
    ), lambda {
      select 'People must apply to join', from: 'Access'
    }
    narrate %(We can then set the questions for the application form.), lambda {
      fill_in 'Application questions', with: "How did you hear about the gathering?\nWhy do you want to participate?"
    }
    execute_script %{window.scrollTo(0, document.body.scrollHeight);}
    narrate %(Let's also enable supporters, and set a magic number. When an application gets this many proposers plus supporters, with at least one proposer, it will be automatically accepted.), lambda {
      execute_script %{$('#gathering_enable_supporters').prop('checked', true)}
      sleep 1
      fill_in 'Magic number', with: 3
    }
    click_link 'Payments'
    narrate %(Under the Payments tab, we'll enter our Stripe API keys so we can accept payments.), lambda {
      fill_in 'Stripe public key', with: @gathering.stripe_pk
      fill_in 'Stripe secret key', with: @gathering.stripe_sk
    }
    click_link 'Features'
    narrate %(OK, that'll do for now. We go to the final tab and click 'Create gathering'.), lambda {
      within('#content') { click_button 'Create gathering' }
    }
    click_link 'Members'
    sleep 1
    narrate %(Under 'Members', we can see the current list of members.)
    click_link 'Applications'
    narrate %(Under 'Applications', we can see outstanding applications and the application link. Let's preview the application form.), lambda {
      visit "/g/#{@gathering.slug}/apply"
    }
    @gathering = Gathering.first
    @gathering.mapplications.create account: @account2, status: 'pending', answers: @gathering.application_questions_a.each_with_index.map { |q, i| [q, "answer #{i}"] }
    visit "/g/#{@gathering.slug}/applications"
    narrate %(This is what we see once someone has applied. We can click Propose to act as a proposer for this application.), lambda {
      click_link 'Propose'
      click_button 'Submit'
      sleep 1
    }
    click_link 'Choose & Pay'
    narrate %(In the 'Choose and Pay' section, let's add a low income tier.)
    click_link 'Add an option'
    narrate %(Provide the tier name, capacity and cost.), lambda {
      fill_in 'Name', with: 'Low income'
      fill_in 'Capacity', with: 100
      fill_in 'Cost', with: 50
    }
    click_button 'Create option'
    narrate %(After adding Standard and Higher income tiers also, it will look like this.), lambda {
      click_link 'Add an option'
      fill_in 'Name', with: 'Standard'
      fill_in 'Capacity', with: 100
      fill_in 'Cost', with: 75
      click_button 'Create option'
      click_link 'Add an option'
      fill_in 'Name', with: 'Higher income'
      fill_in 'Capacity', with: 100
      fill_in 'Cost', with: 100
      click_button 'Create option'
    }
    narrate %(If we then click to join the Standard tier, we see a request for payment.), lambda {
      all('a', text: 'Join')[1].click
    }
    click_link 'Timetables'
    click_link 'Create a timetable'
    narrate %(OK, now let's create a Timetable.), lambda {
      fill_in 'Name', with: 'Main timetable'
    }
    click_button 'Create timetable'
    narrate %(We create some time slots and spaces. Rows are for time slots, and columns are for spaces.), lambda {
      ['Saturday morning', 'Saturday afternoon', 'Sunday morning'].each do |slot|
        fill_in 'New slot', with: slot
        find('input[placeholder="New slot"]').send_keys(:enter)
        sleep 1
      end
      ['The Barn', 'The Piano Room', 'The Garden'].each do |space|
        fill_in 'New space', with: space
        find('input[placeholder="New space"]').send_keys(:enter)
        sleep 1
      end
    }
    click_link 'Propose an activity'
    narrate %(Next let's propose an activity.), lambda {
      fill_in 'tactivity_name', with: 'Piano jam'
    }
    click_button 'Create activity'
    narrate %(Schedule the activity by dragging it onto the timetable.), lambda {
      find('.bi-pencil-fill').click
      select 'Saturday morning', from: 'Slot'
      select 'The Piano Room', from: 'Space'
      click_button 'Update activity'
    }
    click_link 'Shifts'
    click_link 'Create a rota'
    narrate %(Finally, let's create a Rota.), lambda {
      fill_in 'Name', with: 'Kitchen rota'
    }
    click_button 'Create rota'
    narrate %(We'll create some time slots and roles. Rows are for time slots, and columns are for roles.), lambda {
      ['Saturday breakfast', 'Saturday lunch', 'Saturday dinner'].each do |slot|
        fill_in 'New slot', with: slot
        find('input[placeholder="New slot"]').send_keys(:enter)
        sleep 1
      end
      ['Kitchen lead', 'Washing up'].each do |space|
        fill_in 'New role', with: space
        find('input[placeholder="New role"]').send_keys(:enter)
        sleep 1
      end
    }
    narrate %(Click 'Sign up' to sign up to a shift.), lambda {
      all('a', text: 'Sign up')[0].click
    }
    narrate %(That completes the brief tour of Dandelion's Gatherings feature. Happy co-creating!)
    create_video
  end
end
