require_relative '../test_config'

# An organisation's payment settings, contribution to Dandelion, affiliate credit and Stripe Connect
class OrganisationPaymentsTest < ActiveSupport::TestCase
  include Capybara::DSL
  include Rack::Test::Methods

  test 'contribution reminder skips Dandelion Stripe Connect' do
    create_organisation(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json)
    @organisation.set(paid_up: false)

    refute @organisation.contribution_reminder
    assert @organisation.payment_method?
    assert_nil EventPaymentMethod.contribution_reminder_label(@organisation)
  end

  test 'contribution reminder asks unpaid stripe_client_id orgs' do
    create_organisation(stripe_client_id: 'ca_test')
    @organisation.set(paid_up: false)

    assert @organisation.contribution_reminder
    assert_equal 'Stripe Connect', EventPaymentMethod.contribution_reminder_label(@organisation)
  end

  test 'contribution reminder asks unpaid Mollie orgs' do
    create_organisation(stripe_pk: nil, stripe_sk: nil, mollie_api_key: 'test_molliekey')
    @organisation.set(paid_up: false)

    assert @organisation.contribution_reminder
    assert_equal 'Mollie', EventPaymentMethod.contribution_reminder_label(@organisation)
  end

  test 'events count the promotion fee paid for them, and nothing for events without ticket sales' do
    create_organisation(currency: 'GBP')
    create_event(fixed_contribution_gbp: 10)
    create_event(as: :event2, promotion_fee_gbp: 25)
    create_event(as: :event3)

    assert_equal Money.new(25 * 100, 'GBP'), @event2.contribution_gbp
    assert_equal Money.new(0, 'GBP'), @event3.contribution_gbp
    assert_equal Money.new(35 * 100, 'GBP'), @organisation.contribution_requested
  end

  test 'secret keys are masked in the edit form and kept when left blank' do
    create_organisation(mollie_api_key: 'test_molliekey1234')
    sign_in(@account)
    edit_mollie_api_key = lambda do
      visit "/o/#{@organisation.slug}/edit"
      click_link 'Payments'
      find('#payment-mollie')
    end

    mollie = edit_mollie_api_key.call
    key = mollie.find_field('organisation_mollie_api_key')
    assert_equal '', key.value
    assert_equal '••••1234', key[:placeholder]
    refute_includes page.html, 'test_molliekey1234'
    click_button 'Update organisation'
    assert page.has_content? 'The organisation was saved'
    assert_equal 'test_molliekey1234', @organisation.reload.mollie_api_key

    edit_mollie_api_key.call.fill_in 'organisation_mollie_api_key', with: 'test_newkey'
    click_button 'Update organisation'
    assert page.has_content? 'The organisation was saved'
    assert_equal 'test_newkey', @organisation.reload.mollie_api_key

    edit_mollie_api_key.call.find('label', text: 'Remove').click
    click_button 'Update organisation'
    assert page.has_content? 'The organisation was saved'
    assert_nil @organisation.reload.mollie_api_key
  end

  test 'organisation admins cannot set contribution or platform-only fields' do
    create_organisation
    sign_in_with_rack(@account)

    %w[percent_requested hide_from_homepage allow_iframes psychedelic allow_purchase_url no_referrer].each do |f|
      error = assert_raises(RuntimeError) { post "/o/#{@organisation.slug}/edit", organisation: { f => f == 'percent_requested' ? '-1000' : '1' } }
      assert_match(/are protected/, error.message)
    end
    @organisation.reload
    assert_nil @organisation.percent_requested
    refute @organisation.hide_from_homepage
  end

  test 'contribution amounts cannot be negative' do
    create_organisation
    @organisation.percent_requested = -1
    @organisation.fixed_contribution_gbp = -1
    refute @organisation.valid?
    assert @organisation.errors[:percent_requested].any?
    assert @organisation.errors[:fixed_contribution_gbp].any?
  end

  test 'stripe setup session is bound to the organisation' do
    covers_route 'POST /o/:slug/stripe_setup'
    create_organisation
    sign_in_with_rack(@account)

    captured = nil
    Stripe::Checkout::Session.stub :create, proc { |params, _opts|
      captured = params
      api_object(id: 'cs_setup')
    } do
      header 'Accept', 'application/json'
      post "/o/#{@organisation.slug}/stripe_setup"
    end

    assert_equal 200, last_response.status
    assert_equal @organisation.id.to_s, captured[:client_reference_id]
  end

  test 'stripe setup complete rejects a session created for another organisation' do
    covers_route 'GET /o/:slug/stripe_setup_complete'
    create_organisation
    other = FactoryBot.create(:organisation, account: @account)
    sign_in_with_rack(@account)

    session = api_object(mode: 'setup', client_reference_id: other.id.to_s, customer: 'cus_other')
    Stripe::Checkout::Session.stub :retrieve, session do
      get "/o/#{@organisation.slug}/stripe_setup_complete", session_id: 'cs_other'
    end

    assert_equal 400, last_response.status
    assert_nil @organisation.reload.stripe_customer_id
  end

  def enable_affiliate_credits
    create_organisation(currency: 'GBP', affiliate_credit_percentage: 10)
    create_event(prices: [10], suggested_donation: 0)
  end

  # Books quantity tickets for buyer through Stripe, via the link the attendee's order confirmation gives them, and
  # completes the payment
  def book_via_affiliate_link(buyer, affiliate, quantity: 1)
    header 'Accept', 'application/json'
    Stripe::Checkout::Session.stub(:create, api_object(id: "cs_#{SecureRandom.hex(4)}", payment_intent: "pi_#{SecureRandom.hex(4)}", url: 'https://checkout.stripe.com/test')) do
      post "/e/#{@event.slug}/purchase",
           ticketForm: { quantities: { @event.ticket_types.first.id.to_s => quantity.to_s }, affiliate_type: 'Account', affiliate_id: affiliate.id.to_s },
           detailsForm: { payment_method: 'stripe', account: { name: buyer.name, email: buyer.email } }
    end
    assert_equal 200, last_response.status, last_response.body
    order = @event.orders.order('created_at desc').first
    order.set(payment_completed: true)
    order
  end

  test "an attendee's order confirmation email has their personal affiliate link" do
    covers 'organisations/affiliate-link-in-confirmation@7d220b'
    enable_affiliate_credits
    attendee = FactoryBot.create(:account)
    order = @event.orders.create!(account: attendee, currency: 'GBP', value: 10, payment_completed: true)
    @event.tickets.create!(account: attendee, order: order, ticket_type: @event.ticket_types.first, payment_completed: true)

    email = lambda do
      tickets_table = EmailHelper.render(:_tickets_table, event: @event, account: attendee)
      EmailHelper.html(:tickets, event: @event.reload, order: order, account: attendee, tickets_table: tickets_table, header_image_url: nil)
    end
    affiliate_link = "#{ENV['BASE_URI']}/e/#{@event.slug}?affiliate_type=Account&amp;affiliate_id=#{attendee.id}"
    assert_match(/<a href="#{Regexp.escape(affiliate_link)}"[^>]*>Here's your affiliate link for this event.<\/a>/, email.call)
    assert_includes email.call, 'equal to 10% of the order value'

    # The link fills in the booking form's affiliate
    get "/e/#{@event.slug}?affiliate_type=Account&affiliate_id=#{attendee.id}"
    assert_match(/name="affiliate_id"[^>]*value="#{attendee.id}"|value="#{attendee.id}"[^>]*name="affiliate_id"/, last_response.body)

    @organisation.set(affiliate_credit_percentage: nil)
    refute_includes email.call, 'affiliate link'
  end

  test 'a referrer earns the set percentage of each order made via their link as credit, but not on their own orders' do
    covers 'organisations/affiliate-credit-percentage@90cfee'
    enable_affiliate_credits
    referrer = FactoryBot.create(:account)
    referrership = @organisation.organisationships.create!(account: referrer)

    order = book_via_affiliate_link(FactoryBot.create(:account), referrer, quantity: 3)
    assert_equal referrer.id, order.affiliate_id
    assert_equal 30, order.value
    assert_equal Money.new(300, 'GBP'), referrership.credit_granted

    book_via_affiliate_link(FactoryBot.create(:account), referrer)
    assert_equal Money.new(400, 'GBP'), referrership.credit_granted

    # Their own order, via their own link, earns nothing
    own_order = book_via_affiliate_link(referrer, referrer, quantity: 5)
    assert_nil own_order.affiliate_id
    assert_equal Money.new(400, 'GBP'), referrership.reload.credit_granted
    # Nor does one marked as theirs some other way
    own_order.set(affiliate_type: 'Account', affiliate_id: referrer.id)
    assert_equal Money.new(400, 'GBP'), referrership.reload.credit_granted
  end

  test 'credit earned through referrals is applied when the referrer books a future event' do
    covers 'organisations/credit-applied-at-checkout@ebe0b1'
    enable_affiliate_credits
    referrer = FactoryBot.create(:account)
    @organisation.organisationships.create!(account: referrer)
    # Ten £10 tickets booked through their link: £10 of credit
    @event.orders.create!(account: FactoryBot.create(:account), currency: 'GBP', value: 100, affiliate_type: 'Account', affiliate_id: referrer.id,
                          payment_completed: true)
    create_event(as: :future_event, prices: [10], suggested_donation: 0)

    sign_in(referrer)
    visit "/e/#{@future_event.slug}"
    select 1, from: "quantities[#{@future_event.ticket_types.first.id}]"
    click_button 'Use credit'
    assert page.has_content? 'Thanks for booking'
    order = @future_event.orders.find_by(account: referrer)
    assert_equal 10, order.credit_applied
    assert order.payment_completed
    assert_equal Money.new(0, 'GBP'), @organisation.organisationships.find_by(account: referrer).credit_balance
  end

  test "an attendee's credit balance shows on the organisation page, and its breakdown of credit earned and used" do
    covers 'organisations/credit-balance-shown@e73de3'
    covers_route 'GET /organisationships/:id/credit_balance'
    enable_affiliate_credits
    referrer = FactoryBot.create(:account)
    referred = FactoryBot.create(:account, name: 'Referred Person')
    book_via_affiliate_link(referred, referrer, quantity: 3)
    referrership = @organisation.organisationships.find_or_create_by!(account: referrer)
    create_event(as: :future_event, prices: [1], suggested_donation: 0)
    @future_event.orders.create!(account: referrer, currency: 'GBP', value: 0, credit_applied: 1, payment_completed: true)

    sign_in_with_rack(referrer)
    get "/o/#{@organisation.slug}"
    assert last_response.ok?
    assert_includes last_response.body, %(href="/organisationships/#{referrership.id}/credit_balance">£2 credit</a>)

    get "/organisationships/#{referrership.id}/credit_balance"
    assert last_response.ok?
    assert_includes last_response.body, '<span class="badge text-bg-primary">£2</span>'
    assert_includes last_response.body, "£3.00 for Referred Person&#39;s order to #{@event.name}"
    assert_includes last_response.body, "£1.00 on #{@future_event.name}"

    # Not someone else's
    sign_in_with_rack(referred)
    get "/organisationships/#{referrership.id}/credit_balance"
    refute last_response.ok?
    get "/o/#{@organisation.slug}"
    refute_includes last_response.body, 'credit</a>'
  end

  # An organisation taking payment through Dandelion's Stripe Connect, so that checkout donations go to Dandelion
  # while it's behind with its contribution
  def create_stripe_connect_organisation
    create_organisation(currency: 'GBP', stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { 'stripe_user_id' => 'acct_connect' }.to_json)
  end

  # Completed ticket sales of these prices
  def sell_tickets(event, *prices)
    prices.each do |price|
      buyer = FactoryBot.create(:account)
      order = event.orders.create!(account: buyer, currency: event.currency, value: price, payment_completed: true)
      event.tickets.create!(account: buyer, order: order, ticket_type: event.ticket_types.first, price: price, payment_completed: true)
    end
  end

  def contribute(amount)
    @organisation.organisation_contributions.create!(amount: amount, currency: 'GBP', payment_completed: true)
    @organisation.update_paid_up_without_delay
  end

  test 'checkout takes only the donation to Dandelion, never the contribution, out of a ticket sale' do
    covers 'events/contribution-never-from-ticket-sales@73c546'
    create_stripe_connect_organisation
    create_event(prices: [100], suggested_donation: 5)
    @organisation.set(paid_up: false)
    assert @event.reload.donations_to_dandelion?

    checkout = lambda do |ticket_form|
      buyer = FactoryBot.create(:account)
      session_params = nil
      Stripe::Checkout::Session.stub(:create, proc { |params, _opts|
        session_params = params
        api_object(id: "cs_#{buyer.id}", payment_intent: "pi_#{buyer.id}", url: 'https://checkout.stripe.com/test')
      }) do
        header 'Accept', 'application/json'
        post "/e/#{@event.slug}/purchase",
             ticketForm: { quantities: { @event.ticket_types.first.id.to_s => '1' } }.merge(ticket_form),
             detailsForm: { payment_method: 'stripe', account: { name: buyer.name, email: buyer.email } }
      end
      assert_equal 200, last_response.status, last_response.body
      session_params
    end

    assert_equal 0, checkout.call({})[:payment_intent_data][:application_fee_amount]
    assert_equal 500, checkout.call({ donation_amount: '5' })[:payment_intent_data][:application_fee_amount]

    @organisation.set(paid_up: true)
    refute @event.reload.donations_to_dandelion?
    assert_nil checkout.call({ donation_amount: '5' })[:payment_intent_data][:application_fee_amount]
  end

  test 'each ticket sale adds 1% of its price to the contribution, and the Contribute page shows the total, what was contributed and what is left' do
    covers 'events/contribution-never-from-ticket-sales@73c546', 'events/contribution-running-total@535bd5'
    covers_route 'GET /o/:slug/contribute'
    create_stripe_connect_organisation
    create_event(as: :event1, prices: [100])
    create_event(as: :event2, prices: [50])
    create_event(as: :no_sales_event)
    sell_tickets(@event1, 100, 100, 100)
    sell_tickets(@event2, 50, 50)

    assert_equal Money.new(300, 'GBP'), @event1.contribution_gbp
    assert_equal Money.new(100, 'GBP'), @event2.contribution_gbp
    assert_equal Money.new(0, 'GBP'), @no_sales_event.contribution_gbp
    assert_equal Money.new(400, 'GBP'), @organisation.contribution_requested

    contribute(1.5)
    sign_in_with_rack(@account)
    get "/o/#{@organisation.slug}/contribute"
    assert last_response.ok?
    assert_match(/contributed\s+£1.50\s+of a\s+suggested £4,\s+leaving a balance of £2.50\./, last_response.body)
  end

  test 'checkout donations go to the organisation while it has contributed 90% with no more than £100 outstanding, and back to Dandelion when it falls behind' do
    covers 'events/contribution-never-from-ticket-sales@73c546', 'events/contribution-keeping-up@ab2a3a', 'events/checkout-donations-to-dandelion@f1a028'
    create_stripe_connect_organisation
    create_event(prices: [10_000], suggested_donation: 5, minimum_donation: 3)
    sell_tickets(@event, *[10_000] * 10) # £1000 to contribute

    contribute(899)
    refute @organisation.reload.paid_up
    assert @event.reload.donations_to_dandelion?

    contribute(1) # 90%, £100 outstanding
    assert @organisation.reload.paid_up
    refute @event.reload.donations_to_dandelion?
    # The event's Donations settings take effect
    donation = @event.donations.new(account: @account, amount: 2)
    refute donation.valid?
    assert_includes donation.errors[:amount], 'is insufficient'

    # More sales: 90% of £1100 contributed, but £110 outstanding
    sell_tickets(@event, 10_000)
    @organisation.update_paid_up_without_delay
    refute @organisation.reload.paid_up
    assert @event.reload.donations_to_dandelion?
    donation = @event.donations.new(account: @account, amount: 2)
    donation.valid?
    assert_empty donation.errors[:amount]
  end

  test 'auto top-up tops the organisation up to 100% when it falls behind, so checkout donations always go to it' do
    covers 'events/contribution-auto-top-up@6c1573'
    create_stripe_connect_organisation
    create_event(prices: [10_000])
    sell_tickets(@event, *[10_000] * 5) # £500 to contribute
    contribute(450)
    @organisation.set(stripe_customer_id: 'cus_test')

    # Keeping up, so nothing to top up
    Stripe::PaymentIntent.stub(:create, proc { raise 'charged while keeping up' }) { @organisation.stripe_topup }

    @organisation.update_paid_up_without_delay
    assert @organisation.reload.paid_up
    sell_tickets(@event, *[10_000] * 5) # £1000, 45% contributed
    @organisation.update_paid_up_without_delay
    # Behind, but still sending checkout donations to the organisation
    assert @organisation.reload.paid_up
    refute @event.reload.donations_to_dandelion?

    charged = nil
    Stripe::Customer.stub(:list_payment_methods, [api_object(id: 'pm_test')]) do
      Stripe::PaymentIntent.stub(:create, proc { |params, _opts|
        charged = params
        api_object(id: 'pi_topup')
      }) { @organisation.stripe_topup }
    end
    assert_equal [55_000, 'GBP', 'cus_test', 'pm_test'], charged.values_at(:amount, :currency, :customer, :payment_method)
    assert_equal 550, @organisation.organisation_contributions.find_by(payment_intent: 'pi_topup').amount
    assert_equal Money.new(0, 'GBP'), @organisation.contribution_remaining
  end

  # The state in the organisation's Connect Stripe link on its Payments tab, as the signed-in account sees it
  def stripe_connect_state_from_payments_tab
    get "/o/#{@organisation.slug}/edit"
    link = Nokogiri::HTML(last_response.body).at_css('a[href^="https://connect.stripe.com/oauth/authorize"]')
    assert link, 'no Connect Stripe link on the Payments tab'
    Rack::Utils.parse_query(URI(link['href']).query).fetch('state')
  end

  # Stripe's OAuth token exchange and account lookup, answering for acct_own and recording the codes exchanged, so no
  # request reaches Stripe
  def stub_stripe_connect(&)
    exchanged = []
    connection = Object.new
    connection.define_singleton_method(:post) do |url, body|
      exchanged << [url, body[:code]]
      Struct.new(:success?, :body).new(true, { stripe_user_id: 'acct_own' }.to_json)
    end
    Faraday.stub(:new, ->(*) { connection }) do
      Stripe::Account.stub(:retrieve, ->(id, _opts) { { id: id, business_profile: { name: 'Own Ltd' } } }, &)
    end
    exchanged
  end

  def stripe_connect_callback(state)
    get '/organisations/stripe_connect', code: 'ac_code', state: state
  end

  test "an organisation admin's own Connect state connects the Stripe account they authorised" do
    covers_route 'GET /o/:slug/edit'
    create_organisation(stripe_pk: nil, stripe_sk: nil)
    sign_in_with_rack(@account)
    state = stripe_connect_state_from_payments_tab

    exchanged = stub_stripe_connect { stripe_connect_callback(state) }

    assert_equal [['https://connect.stripe.com/oauth/token', 'ac_code']], exchanged
    assert_equal 'acct_own', @organisation.reload.stripe_user_id
    assert_equal 'Own Ltd', @organisation.stripe_account_name
    assert_equal "/o/#{@organisation.slug}/edit", URI(last_response.location).path
  end

  test "a Connect state started by one account doesn't connect the organisation when another admin opens its callback" do
    create_organisation(stripe_pk: nil, stripe_sk: nil)
    other_admin = FactoryBot.create(:account)
    other_admin.organisationships.create!(organisation: @organisation, admin: true)
    assert Organisation.admin?(@organisation, other_admin)
    sign_in_with_rack(other_admin)
    state = stripe_connect_state_from_payments_tab

    sign_in_with_rack(@account)
    exchanged = stub_stripe_connect { stripe_connect_callback(state) }

    assert_empty exchanged
    assert_nil @organisation.reload.stripe_connect_json
    follow_redirect!
    assert_includes last_response.body, 'Stripe connection failed security check'
  end

  test 'a Connect state minted without an account, before states were bound to one, is refused' do
    covers_route 'GET /organisations/stripe_connect'
    create_organisation(stripe_pk: nil, stripe_sk: nil)
    state = TokenVerifier.generate("stripe_connect_org:#{@organisation.id}", expires_in: 15.minutes, purpose: 'stripe_connect')
    sign_in_with_rack(@account)

    exchanged = stub_stripe_connect { stripe_connect_callback(state) }

    assert_empty exchanged
    assert_nil @organisation.reload.stripe_connect_json
  end

  test 'the Payments tab shows the connected Stripe account and offers to disconnect it' do
    create_organisation(stripe_pk: nil, stripe_sk: nil, stripe_connect_json: { stripe_user_id: 'acct_connected' }.to_json, stripe_account_json: { business_profile: { name: 'Connected Ltd' } }.to_json)
    sign_in(@account)
    visit "/o/#{@organisation.slug}/edit"
    click_link 'Payments'

    assert page.has_content?("Connected to Connected Ltd's Stripe account (id: acct_connected)")
    assert page.has_link?('Disconnect')
  end
end
