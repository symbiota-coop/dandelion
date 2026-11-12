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
      ['ch_1', "#{EVENT}: Standard £10x2", '20.0', 'gbp'],
      ['ch_1', "#{EVENT}: Concession £5x1", '5.0', 'gbp']
    ], rows
  end

  test 'splits each row of the CSV, and drops rows with no description' do
    rows = split(
      ['ch_1', "#{EVENT}: £12x1", '12.00', 'gbp'],
      ['ch_2', '', '3.00', 'gbp'],
      ['ch_3', "#{EVENT}: Standard £8x3", '24.00', 'gbp']
    )
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: £12x1", '12.0', 'gbp'],
      ['ch_3', "#{EVENT}: Standard £8x3", '24.0', 'gbp']
    ], rows
  end

  test 'a CSV with only blank descriptions gives just the header' do
    assert_equal [header], split(['ch_1', '', '5.00', 'gbp'])
  end

  test 'takes a percentage discount off each ticket type and names it on each row, rounding to the penny' do
    rows = split(['ch_1', "#{EVENT}: Standard £7.99x3, Concession £5x1, 10% discount", '26.07', 'gbp'])
    # 23.97 less 10% is 21.573
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: Standard £7.99x3, 10% discount", '21.57', 'gbp'],
      ['ch_1', "#{EVENT}: Concession £5x1, 10% discount", '4.5', 'gbp']
    ], rows
  end

  test 'takes a fixed discount off a single ticket type' do
    rows = split(['ch_1', "#{EVENT}: Standard £25x2, £5 discount", '45.00', 'gbp'])
    assert_equal [header, ['ch_1', "#{EVENT}: Standard £25x2, £5 discount", '45.0', 'gbp']], rows
  end

  test 'takes the percentage off before the fixed discount' do
    rows = split(['ch_1', "#{EVENT}: Standard £50x1, 10% discount, £5 discount", '40.00', 'gbp'])
    assert_equal [header, ['ch_1', "#{EVENT}: Standard £50x1, 10% discount, £5 discount", '40.0', 'gbp']], rows
  end

  test 'reads prices and discounts with thousands separators, and writes the discount with them' do
    rows = split(['ch_1', "#{EVENT}: Patron £1,000x2, £1,500 discount", '500.00', 'gbp'])
    assert_equal [header, ['ch_1', "#{EVENT}: Patron £1,000x2, £1,500 discount", '500.0', 'gbp']], rows
  end

  test 'gives a donation its own row after the tickets, undiscounted' do
    # Order#description leaves a space after "donation" when it isn't to Dandelion
    rows = split(['ch_1', "#{EVENT}: Standard £10x1, 20% discount, £5 donation ", '13.00', 'gbp'])
    assert_equal [
      header,
      ['ch_1', "#{EVENT}: Standard £10x1, 20% discount", '8.0', 'gbp'],
      ['ch_1', "#{EVENT}: £5 donation", '5.0', 'gbp']
    ], rows
  end

  test 'leaves out a donation to Dandelion, which is the application fee rather than the organisation’s income' do
    rows = split(['ch_1', "#{EVENT}: Standard £10x1, £3 donation to Dandelion", '13.00', 'gbp'])
    assert_equal [header, ['ch_1', "#{EVENT}: Standard £10x1", '10.0', 'gbp']], rows
  end
end
