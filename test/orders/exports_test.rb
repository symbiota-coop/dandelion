require_relative '../test_config'

# The order and ticket exports (CSV and PDF, app/controllers/orders_admin.rb and Order.generate_csv), and who sees
# attendees' email addresses in them: organisation admins, event admins when the event shows emails, and an event's
# facilitators for orders that opted in to them, but no other event admin
class OrdersExportsTest < ActiveSupport::TestCase
  include Rack::Test::Methods

  QUESTIONS = ['Dietary needs?', 'T-shirt size?'].freeze

  # An event with two questions and two orders, each with a ticket: Ada answered both questions and bought a ticket for
  # a friend; Bea answered neither and opted in to sharing her email with the facilitator
  def create_orders(show_emails: false)
    create_event(prices: [10], questions: QUESTIONS.join("\n"), show_emails: show_emails)
    @ada = FactoryBot.create(:account, name: 'Ada Lovelace', email: 'ada@example.com')
    @bea = FactoryBot.create(:account, name: 'Bea Smith', email: 'bea@example.com')
    @ada_order = create_attendee_order(@ada, answers: [[QUESTIONS[0], 'Vegan'], [QUESTIONS[1], 'M']])
    @ada_order.tickets.create!(event: @event, account: @ada, ticket_type: @event.ticket_types.first, price: 10,
                               name: 'Friend Person', email: 'friend@example.com')
    @bea_order = create_attendee_order(@bea, opt_in_facilitator: true)
    @bea_order.tickets.create!(event: @event, account: @bea, ticket_type: @event.ticket_types.first, price: 10,
                               name: 'Bea Guest', email: 'bea.guest@example.com')
    @facilitator = create_facilitator(@event)
  end

  def create_attendee_order(account, **attrs)
    @event.orders.create!(account: account, currency: @event.currency, value: 10, payment_completed: true, **attrs)
  end

  def csv_rows(path)
    get path
    assert_equal 200, last_response.status
    assert_includes last_response.content_type, 'text/csv'
    CSV.parse(last_response.body, headers: true)
  end

  def row_for(rows, name)
    rows.find { |row| row['name'] == name } || flunk("No row for #{name}")
  end

  # The PDF's table, as a hash for each row keyed by the header row's cells. Prawn writes each cell's text at its own
  # position as a hex string (with our font, each character as its own code), and leaves empty cells out, so cells are
  # matched to columns by where they start, and to rows by their height on the page
  def pdf_rows(path)
    get path
    assert_equal 200, last_response.status
    assert_includes last_response.content_type, 'application/pdf'
    cells = last_response.body.scan(%r{([\d.]+) ([\d.]+) Td\n/\S+ [\d.]+ Tf\n<(\h*)> Tj}).map do |x, y, hex|
      [x, y, [hex].pack('H*').force_encoding('UTF-8')]
    end
    header, *rows = cells.chunk_while { |a, b| a[1] == b[1] }.to_a
    columns = header.to_h { |x, _y, text| [x, text] }
    rows.map { |row| columns.values.index_with('').merge(row.to_h { |x, _y, text| [columns.fetch(x), text] }) }
  end

  # Event orders

  test 'an organisation admin exports the event orders with every email and answer' do
    create_orders
    sign_in_with_rack(@account)

    rows = csv_rows("/e/#{@event.slug}/orders.csv")
    assert_equal QUESTIONS, rows.headers.last(2)
    ada = row_for(rows, 'Ada Lovelace')
    assert_equal ['Ada', 'Lovelace', 'ada@example.com', @event.name, 'Vegan', 'M'],
                 ada.values_at('firstname', 'lastname', 'email', 'event_name', *QUESTIONS)
    bea = row_for(rows, 'Bea Smith')
    assert_equal 'bea@example.com', bea['email']
    assert_equal [nil, nil], bea.values_at(*QUESTIONS)
  end

  test "an event's facilitator exports its orders without emails, but for orders that opted in to them" do
    covers_route 'GET /e/:slug/orders'
    create_orders
    sign_in_with_rack(@facilitator)

    rows = csv_rows("/e/#{@event.slug}/orders.csv")
    ada = row_for(rows, 'Ada Lovelace')
    assert_equal '', ada['email']
    assert_equal %w[Vegan M], ada.values_at(*QUESTIONS)
    assert_equal 'bea@example.com', row_for(rows, 'Bea Smith')['email']
  end

  test "an event's facilitator sees every email in its orders when the event shows emails" do
    create_orders(show_emails: true)
    sign_in_with_rack(@facilitator)

    rows = csv_rows("/e/#{@event.slug}/orders.csv")
    assert_equal 'ada@example.com', row_for(rows, 'Ada Lovelace')['email']
    assert_equal 'bea@example.com', row_for(rows, 'Bea Smith')['email']
  end

  test 'the event orders PDF shows emails to an organisation admin and only opted-in ones to a facilitator' do
    create_orders
    sign_in_with_rack(@account)
    rows = pdf_rows("/e/#{@event.slug}/orders.pdf")
    assert_equal([['Ada Lovelace', 'ada@example.com'], ['Bea Smith', 'bea@example.com']], rows.map { |row| row.values_at('name', 'email') })

    sign_in_with_rack(@facilitator)
    rows = pdf_rows("/e/#{@event.slug}/orders.pdf")
    assert_equal([['Ada Lovelace', ''], ['Bea Smith', 'bea@example.com']], rows.map { |row| row.values_at('name', 'email') })
  end

  test "someone who doesn't admin the event can't export its orders or tickets" do
    create_orders
    sign_in_with_rack(@ada)
    %w[orders.csv orders.pdf tickets.csv tickets.pdf].each do |export|
      get "/e/#{@event.slug}/#{export}"
      refute_equal 200, last_response.status, export
      refute_includes last_response.body, 'bea@example.com', export
    end
  end

  # Event tickets

  test "an organisation admin exports the event's tickets with the accounts' and the tickets' own emails" do
    create_orders
    sign_in_with_rack(@account)

    rows = csv_rows("/e/#{@event.slug}/tickets.csv")
    ada = row_for(rows, 'Ada Lovelace')
    assert_equal ['Ada', 'Lovelace', 'ada@example.com', 'Friend Person', 'friend@example.com'],
                 ada.values_at('firstname', 'lastname', 'email', 'ordered_for_name', 'ordered_for_email')
    bea = row_for(rows, 'Bea Smith')
    assert_equal ['bea@example.com', 'Bea Guest', 'bea.guest@example.com'], bea.values_at('email', 'ordered_for_name', 'ordered_for_email')
  end

  test "an event's facilitator exports its tickets without emails, but for orders that opted in to them" do
    covers_route 'GET /e/:slug/tickets'
    create_orders
    sign_in_with_rack(@facilitator)

    rows = csv_rows("/e/#{@event.slug}/tickets.csv")
    ada = row_for(rows, 'Ada Lovelace')
    assert_equal ['Friend Person', '', ''], ada.values_at('ordered_for_name', 'email', 'ordered_for_email')
    bea = row_for(rows, 'Bea Smith')
    assert_equal ['bea@example.com', 'bea.guest@example.com'], bea.values_at('email', 'ordered_for_email')
  end

  test 'the event tickets PDF shows emails to an organisation admin and only opted-in ones to a facilitator' do
    create_orders
    columns = %w[name email ordered_for_name ordered_for_email]
    sign_in_with_rack(@account)
    rows = pdf_rows("/e/#{@event.slug}/tickets.pdf")
    assert_equal([['Ada Lovelace', 'ada@example.com', 'Friend Person', 'friend@example.com'],
                  ['Bea Smith', 'bea@example.com', 'Bea Guest', 'bea.guest@example.com']], rows.map { |row| row.values_at(*columns) })

    sign_in_with_rack(@facilitator)
    rows = pdf_rows("/e/#{@event.slug}/tickets.pdf")
    assert_equal([['Ada Lovelace', '', 'Friend Person', ''],
                  ['Bea Smith', 'bea@example.com', 'Bea Guest', 'bea.guest@example.com']], rows.map { |row| row.values_at(*columns) })
  end

  # Organisation orders

  test "an organisation admin exports the organisation's orders with emails and each order's event" do
    covers_route 'GET /o/:slug/orders'
    create_orders
    other_event = create_event(prices: [10], as: :other_event)
    carl = FactoryBot.create(:account, name: 'Carl Jones', email: 'carl@example.com')
    other_event.orders.create!(account: carl, currency: other_event.currency, value: 10, payment_completed: true)
    sign_in_with_rack(@account)

    rows = csv_rows("/o/#{@organisation.slug}/orders.csv")
    # Without an event, there are no question columns
    assert_equal 'created_at', rows.headers.last
    assert_equal ['ada@example.com', @event.name, @event.slug], row_for(rows, 'Ada Lovelace').values_at('email', 'event_name', 'event_slug')
    assert_equal ['bea@example.com', @event.name], row_for(rows, 'Bea Smith').values_at('email', 'event_name')
    assert_equal ['carl@example.com', other_event.name, other_event.slug], row_for(rows, 'Carl Jones').values_at('email', 'event_name', 'event_slug')
  end

  test "an event's facilitator can't export the organisation's orders" do
    create_orders
    sign_in_with_rack(@facilitator)
    get "/o/#{@organisation.slug}/orders.csv"
    refute_equal 200, last_response.status
    refute_includes last_response.body, 'ada@example.com'
  end

  # Order.generate_csv decides for each order, so a facilitator who opted-in orders show emails to sees only those
  test 'Order.generate_csv blanks the emails of orders the account may not see' do
    create_orders
    rows = CSV.parse(@event.orders.generate_csv(account: @facilitator, event: @event), headers: true)
    assert_equal({ 'Ada Lovelace' => '', 'Bea Smith' => 'bea@example.com' }, rows.to_h { |row| [row['name'], row['email']] })
    rows = CSV.parse(@event.orders.generate_csv(account: nil, event: @event), headers: true)
    assert_equal(['', ''], rows.map { |row| row['email'] })
  end
end
