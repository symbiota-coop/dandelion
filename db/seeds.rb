require 'factory_bot'

[Account, Event, Organisation, Gathering, Event].map(&:destroy_all)
FactoryBot.create_list(:account, 2)
@account = FactoryBot.create(:account, admin: true, name: ENV['SEED_ACCOUNT_NAME'], email: ENV['SEED_ACCOUNT_EMAIL'], password: ENV['SEED_ACCOUNT_PASSWORD'])
@gathering = FactoryBot.create(:gathering, account: @account, name: 'Nettlecombe', slug: 'nettlecombe')
@organisation = FactoryBot.create(:organisation, account: @account, name: 'Autopia', slug: 'autopia', paid_up: true)
@event = FactoryBot.create_list(:event, 4, organisation: @organisation, account: @account, last_saved_by: @account, image: open(Padrino.root('app/assets/images/test-event.jpg')), featured: true)
