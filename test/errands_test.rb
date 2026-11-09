require File.expand_path("#{File.dirname(__FILE__)}/test_config.rb")

class ErrandsTest < ActiveSupport::TestCase
  test 'a step prints its label as it starts and with how long it took once done' do
    out, = capture_io { assert_equal :result, Errand.step('count things') { :result } }

    assert_match(/\Acount things\ncount things: \d+\.\ds\n\z/, out)
  end

  test 'a step that fails still prints how long it took, then raises' do
    out, = capture_io do
      assert_raises(RuntimeError) { Errand.step('break things') { raise 'broken' } }
    end

    assert_match(/\Abreak things\nbreak things: \d+\.\ds\n\z/, out)
  end

  test 'steps nest, so a task prints its total after its steps' do
    out, = capture_io { Errand.step('errands') { Errand.step('one') { nil } } }

    labels = out.lines.map { |line| line.chomp.sub(/\d+\.\ds\z/, '') }
    assert_equal ['errands', 'one', 'one: ', 'errands: '], labels
  end

  test 'durations of a minute or more are given in minutes and seconds' do
    assert_equal '0.3s', Errand.duration(0.31)
    assert_equal '59.9s', Errand.duration(59.94)
    assert_equal '1m00s', Errand.duration(60)
    assert_equal '4m12s', Errand.duration(251.6)
  end
end
