require_relative '../test_config'

# Splitting each row of a Stripe payments CSV (POST /stripe_row_splitter) into a row per ticket type and one for the
# donation, from the order description (Order#description) that's the payment's Stripe description
class PaymentsStripeRowSplitterTest < ActiveSupport::TestCase
  EVENT = 'Bach Cantatas, Tue 3 Feb 2026, 19:00 at St Mary, London'.freeze

  def split(*rows)
    input = CSV.generate do |csv|
      csv << %w[id Description Amount Currency]
      rows.each { |row| csv << row }
    end
    CSV.parse(StripeRowSplitter.split(input))
  end

  def header
    %w[id Description Amount Currency]
  end

  test 'gives each ticket type its own row, at price times quantity, keeping the other columns' do
    rows = split(['ch_1', "#{EVENT}: Standard £10x2, Concession £5x1", '25.00', 'gbp'])
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: Standard £10x2", '20.00', 'gbp'],
      ['ch_1', "#{EVENT}: Concession £5x1", '5.00', 'gbp']
    ], rows
  end

  test 'splits each row of the CSV, keeping a row with no description as it is' do
    rows = split(
      ['ch_1', "#{EVENT}: £12x1", '12.00', 'gbp'],
      ['ch_2', '', '3.00', 'gbp'],
      ['ch_3', "#{EVENT}: Standard £8x3", '24.00', 'gbp']
    )
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: £12x1", '12.00', 'gbp'],
      ['ch_2', '', '3.00', 'gbp'],
      ['ch_3', "#{EVENT}: Standard £8x3", '24.00', 'gbp']
    ], rows
  end

  test 'leaves out blank lines' do
    input = "#{CSV.generate_line(header)}#{CSV.generate_line(['ch_1', "#{EVENT}: £12x1", '12.00', 'gbp'])}\n"
    assert_equal [header, ['ch_1', "#{EVENT}: £12x1", '12.00', 'gbp']], CSV.parse(StripeRowSplitter.split(input))
  end

  test 'takes a percentage discount off each ticket type and names it on each row, rounding to the penny' do
    rows = split(['ch_1', "#{EVENT}: Standard £7.99x3, Concession £5x1, 10% discount", '26.07', 'gbp'])
    # 23.97 less 10% is 21.573
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: Standard £7.99x3, 10% discount", '21.57', 'gbp'],
      ['ch_1', "#{EVENT}: Concession £5x1, 10% discount", '4.50', 'gbp']
    ], rows
  end

  test 'takes a fixed discount off a single ticket type' do
    rows = split(['ch_1', "#{EVENT}: Standard £25x2, £5 discount", '45.00', 'gbp'])
    assert_equal [header, ['ch_1', "#{EVENT}: Standard £25x2, £5 discount", '45.00', 'gbp']], rows
  end

  test 'takes the percentage off before the fixed discount' do
    rows = split(['ch_1', "#{EVENT}: Standard £50x1, 10% discount, £5 discount", '40.00', 'gbp'])
    assert_equal [header, ['ch_1', "#{EVENT}: Standard £50x1, 10% discount, £5 discount", '40.00', 'gbp']], rows
  end

  test 'reads prices and discounts with thousands separators, and writes the discount with them' do
    rows = split(['ch_1', "#{EVENT}: Patron £1,000x2, £1,500 discount", '500.00', 'gbp'])
    assert_equal [header, ['ch_1', "#{EVENT}: Patron £1,000x2, £1,500 discount", '500.00', 'gbp']], rows
  end

  test 'gives a donation its own row after the tickets, undiscounted' do
    # Order#description leaves a space after "donation" when it isn't to Dandelion
    rows = split(['ch_1', "#{EVENT}: Standard £10x1, 20% discount, £5 donation ", '13.00', 'gbp'])
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: Standard £10x1, 20% discount", '8.00', 'gbp'],
      ['ch_1', "#{EVENT}: £5 donation", '5.00', 'gbp']
    ], rows
  end

  test 'leaves out a donation to Dandelion, which is the application fee rather than the organisation’s income' do
    rows = split(['ch_1', "#{EVENT}: Standard £10x1, £3 donation to Dandelion", '13.00', 'gbp'])
    assert_equal [header, ['ch_1', "#{EVENT}: Standard £10x1", '10.00', 'gbp']], rows
  end

  # Each split row's Amount in pence, by the id of the payment it came from
  def pence_by_payment(rows)
    rows.drop(1).group_by(&:first).transform_values { |payment_rows| payment_rows.sum { |row| (BigDecimal(row[2]) * 100).to_i } }
  end

  test 'spreads a fixed discount across the ticket types in proportion to their amounts, rather than taking it off each' do
    rows = split(
      ['ch_1', "#{EVENT}: A £10x1, B £10x1, £5 discount", '15.00', 'gbp'],
      ['ch_2', "#{EVENT}: A £10x1, B £5x2, C £5x1, £5 discount", '20.00', 'gbp']
    )
    # ch_1: £2.50 off each £10; ch_2: £5 is a fifth of the £25, so £2 off A's £10, £2 off B's £10 and £1 off C's £5
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: A £10x1, £5 discount", '7.50', 'gbp'],
      ['ch_1', "#{EVENT}: B £10x1, £5 discount", '7.50', 'gbp'],
      ['ch_2', "#{EVENT}: A £10x1, £5 discount", '8.00', 'gbp'],
      ['ch_2', "#{EVENT}: B £5x2, £5 discount", '8.00', 'gbp'],
      ['ch_2', "#{EVENT}: C £5x1, £5 discount", '4.00', 'gbp']
    ], rows
    assert_equal({ 'ch_1' => 1500, 'ch_2' => 2000 }, pence_by_payment(rows))
  end

  test 'rounds each share of a fixed discount to the penny, putting the remainder on the largest row' do
    rows = split(['ch_1', "#{EVENT}: A £10x1, B £10x1, C £10x1, £10 discount", '20.00', 'gbp'])
    # A third of £10 is £3.333..., so B and C have £3.33 off, and A, the first of the largest, the other £3.34
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: A £10x1, £10 discount", '6.66', 'gbp'],
      ['ch_1', "#{EVENT}: B £10x1, £10 discount", '6.67', 'gbp'],
      ['ch_1', "#{EVENT}: C £10x1, £10 discount", '6.67', 'gbp']
    ], rows
    assert_equal({ 'ch_1' => 2000 }, pence_by_payment(rows))
  end

  test 'takes credit applied off the tickets' do
    rows = split(['ch_1', "#{EVENT}: A £10x2, £3 credit applied", '17.00', 'gbp'])
    assert_equal [header, ['ch_1', "#{EVENT}: A £10x2, £3 credit applied", '17.00', 'gbp']], rows
  end

  test 'takes percentage discounts off first, then spreads credit and a fixed discount across what is left' do
    rows = split(['ch_1', "#{EVENT}: A £20x1, B £10x1, 10% discount, £6 credit applied, £3 discount", '18.00', 'gbp'])
    # A is £18 and B £9 after 10% off; the £9 of credit and discount is a third of the £27, so £6 off A and £3 off B
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: A £20x1, 10% discount, £6 credit applied, £3 discount", '12.00', 'gbp'],
      ['ch_1', "#{EVENT}: B £10x1, 10% discount, £6 credit applied, £3 discount", '6.00', 'gbp']
    ], rows
    assert_equal({ 'ch_1' => 1800 }, pence_by_payment(rows))
  end

  test 'takes credit beyond the tickets off the donation, as an order does' do
    # Order#description leaves a space after "donation", which comes before the credit
    rows = split(['ch_1', "#{EVENT}: Standard £10x1, £5 donation , £12 credit applied", '3.00', 'gbp'])
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: Standard £10x1, £12 credit applied", '0.00', 'gbp'],
      ['ch_1', "#{EVENT}: £5 donation, £12 credit applied", '3.00', 'gbp']
    ], rows
  end

  test 'applies both percentage discounts, one after the other, to each ticket rounded to the penny' do
    rows = split(
      ['ch_1', "#{EVENT}: Standard £10x1, 20% discount, 10% discount", '7.20', 'gbp'],
      ['ch_2', "#{EVENT}: Standard £7.99x3, 20% discount, 10% discount", '17.25', 'gbp']
    )
    # ch_1: £10 less 20% is £8, less 10% £7.20; ch_2: £7.99 less 20% less 10% is £5.7528, so £5.75 a ticket, £17.25
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: Standard £10x1, 20% discount, 10% discount", '7.20', 'gbp'],
      ['ch_2', "#{EVENT}: Standard £7.99x3, 20% discount, 10% discount", '17.25', 'gbp']
    ], rows
  end

  test 'reads amounts in the currency of the row, as Money writes them' do
    rows = split(
      ['ch_1', "#{EVENT}: Standard €12,50x2, Patron €1.000x1, €5 discount, €5 donation ", '1025.00', 'eur'],
      ['ch_2', "#{EVENT}: $10x1, 10% discount", '9.00', 'usd'],
      ['ch_3', "#{EVENT}: Standard 1 234,50 złx1, Concession 100 złx1, 50 zł discount", '1284.50', 'pln'],
      ['ch_4', "#{EVENT}: Standard CHF 1'000x1", '1000.00', 'chf'],
      ['ch_5', "#{EVENT}: Standard SEK 1,234.50x1", '1234.50', 'sek']
    )
    # ch_1: the €5 discount is spread over €1,025 of tickets: €0.12 (rounded from 0.1219...) off the €25, and the other
    # €4.88 off the €1,000. ch_3: the 50 zł is spread over 1,334.50 zł: 3.75 zł (3.7467...) off the 100 zł, and the
    # other 46.25 zł off the 1,234.50 zł
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: Standard €12,50x2, €5 discount", '24.88', 'eur'],
      ['ch_1', "#{EVENT}: Patron €1.000x1, €5 discount", '995.12', 'eur'],
      ['ch_1', "#{EVENT}: €5 donation", '5.00', 'eur'],
      ['ch_2', "#{EVENT}: $10x1, 10% discount", '9.00', 'usd'],
      ['ch_3', "#{EVENT}: Standard 1 234,50 złx1, 50 zł discount", '1188.25', 'pln'],
      ['ch_3', "#{EVENT}: Concession 100 złx1, 50 zł discount", '96.25', 'pln'],
      ['ch_4', "#{EVENT}: Standard CHF 1'000x1", '1000.00', 'chf'],
      ['ch_5', "#{EVENT}: Standard SEK 1,234.50x1", '1234.50', 'sek']
    ], rows
    assert_equal({ 'ch_1' => 102_500, 'ch_2' => 900, 'ch_3' => 128_450, 'ch_4' => 100_000, 'ch_5' => 123_450 }, pence_by_payment(rows))
  end

  test 'finds the order\'s parts after an event name with a colon in it' do
    rows = split(['ch_1', "Bach: Cantatas, Tue 3 Feb 2026, 19:00: Standard £10x1, Concession £5x1", '15.00', 'gbp'])
    assert_equal [
      header,
      ['ch_1', 'Bach: Cantatas, Tue 3 Feb 2026, 19:00: Standard £10x1', '10.00', 'gbp'],
      ['ch_1', 'Bach: Cantatas, Tue 3 Feb 2026, 19:00: Concession £5x1', '5.00', 'gbp']
    ], rows
  end

  test 'keeps a row it can\'t read, or whose parts don\'t come to its amount, as it is' do
    unsplit = [
      ['ch_1', 'Tue 3 Feb 2026, 19:00 at St Mary, London', '10.00', 'gbp'],
      ['ch_2', "#{EVENT}: Standard £10x1, Gift aid", '10.00', 'gbp'],
      ['ch_3', "#{EVENT}: Standard £10x1", '12.00', 'gbp'],
      ['ch_4', "#{EVENT}: Standard £10x1", '10.00', 'xyz'],
      ['ch_5', "#{EVENT}: Standard £10x1, 10% discount, 10% discount, 10% discount", '7.29', 'gbp']
    ]
    assert_equal [header] + unsplit, split(*unsplit)
  end

  test 'writes amounts with two decimal places, as Stripe does' do
    rows = split(['ch_1', "#{EVENT}: Standard £10x1, £2.50 donation ", '12.50', 'gbp'])
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: Standard £10x1", '10.00', 'gbp'],
      ['ch_1', "#{EVENT}: £2.50 donation", '2.50', 'gbp']
    ], rows
  end
end
