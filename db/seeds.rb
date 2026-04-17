require 'factory_bot'

@account = FactoryBot.create(:account, admin: true, name: ENV['SEED_ACCOUNT_NAME'], email: ENV['SEED_ACCOUNT_EMAIL'], password: ENV['SEED_ACCOUNT_PASSWORD'])
FactoryBot.create_list(:account, 2)
@organisation = FactoryBot.create(:organisation, account: @account, name: 'Test Organisation', slug: 'test-organisation', paid_up: true)
FactoryBot.create_list(:event, 9, organisation: @organisation, account: @account, last_saved_by: @account, image: File.open(Padrino.root('app/assets/images/test-event.jpg')), featured: true, prices: [0])
FactoryBot.create(:gathering, account: @account, name: 'Test Gathering', slug: 'test-gathering')
