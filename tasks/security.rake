namespace :security do
  # A BSON ObjectId is 4 bytes of timestamp, 5 bytes that are fixed for the life of
  # the process that generated it, and a 3-byte counter that is seeded randomly at
  # boot and then incremented once per document that process inserts — across every
  # collection, not just this one.
  #
  # So the counter gap between two consecutive orders from the same worker is the
  # number of documents that worker inserted in between, which is exactly the search
  # space someone faces when guessing order ids. This measures that gap on real data.
  #
  #   MODEL=Order LIMIT=2000 WINDOW=10 rake security:objectid_entropy
  #
  # WINDOW is how tightly an attacker can pin the purchase time, in seconds.
  # MODEL=PageView gives a cleaner estimate of the underlying insert rate, since the
  # counter is shared and page views are dense.
  desc 'Measure how guessable ObjectIds are (MODEL=Order LIMIT=2000 WINDOW=10)'
  task objectid_entropy: :environment do
    counter_space = 2**24
    model = (ENV['MODEL'] || 'Order').constantize
    limit = (ENV['LIMIT'] || 2000).to_i
    window = (ENV['WINDOW'] || 10).to_i

    # 24 hex chars: 0-7 timestamp, 8-17 per-process value, 18-23 counter.
    decompose = lambda do |id|
      hex = id.to_s
      { time: hex[0, 8].to_i(16), worker: hex[8, 10], counter: hex[18, 6].to_i(16) }
    end

    median = lambda do |a|
      return nil if a.empty?

      s = a.sort
      s.length.odd? ? s[s.length / 2] : (s[(s.length / 2) - 1] + s[s.length / 2]) / 2.0
    end

    rows = model.unscoped.order('_id desc').limit(limit).pluck(:id).map(&decompose)

    if rows.length < 2
      puts "Not enough #{model} documents to measure (found #{rows.length})."
      next
    end

    by_worker = rows.group_by { |r| r[:worker] }
    times = rows.map { |r| r[:time] }

    puts "\n📊 #{model}: #{rows.length} ids, #{by_worker.size} worker(s)"
    puts "   #{Time.at(times.min).utc} → #{Time.at(times.max).utc}"
    puts '=' * 78

    rates = []
    gaps = []
    wraps = 0

    by_worker.sort_by { |_, g| -g.length }.each do |worker, group|
      group = group.sort_by { |r| [r[:time], r[:counter]] }

      pairs = group.each_cons(2).map do |a, b|
        dc = b[:counter] - a[:counter]
        wrapped = dc.negative?
        wraps += 1 if wrapped
        dc += counter_space if wrapped
        { dt: b[:time] - a[:time], dc: dc, wrapped: wrapped }
      end

      timed = pairs.select { |p| p[:dt].positive? }
      worker_rates = timed.map { |p| p[:dc].to_f / p[:dt] }
      worker_gaps = pairs.map { |p| p[:dc] }

      rates.concat(worker_rates)
      gaps.concat(worker_gaps)

      puts "\n   worker #{worker}  (#{group.length} ids)"
      puts "     median counter gap between consecutive docs: #{median.call(worker_gaps)&.round}"
      puts "     median insert rate:                          #{median.call(worker_rates)&.round(2)}/sec"
      puts "     counter wraps seen:                          #{pairs.count { |p| p[:wrapped] }}"
    end

    rate = median.call(rates)

    if rate.nil? || rate.zero?
      puts "\n⚠️  Could not derive an insert rate (all sampled ids share a timestamp)."
      puts "   Retry with a larger LIMIT, or MODEL=PageView.\n\n"
      next
    end

    # A targeted attacker enumerates (timestamp, counter) pairs inside the window.
    timestamps = (2 * window) + 1
    counters = (rate * 2 * window).ceil + 1
    candidates = timestamps * counters * by_worker.size

    puts "\n#{'=' * 78}"
    puts "🎯 Targeted guess, purchase time known to ±#{window}s:"
    puts "     #{timestamps} timestamps × #{counters} counters × #{by_worker.size} worker(s)"
    puts "     ≈ #{candidates.to_s.reverse.scan(/\d{1,3}/).join(',').reverse} candidate ids  (~2^#{Math.log2(candidates).round(1)})"
    puts "     vs 2^128 for SecureRandom.urlsafe_base64(16)"
    puts "\n   Days for the counter to wrap at this rate: #{(counter_space / rate / 86_400).round(1)}"
    puts "   (wraps observed in sample: #{wraps}#{wraps.positive? ? ' — rates above are a lower bound' : ''})"
    puts "\n   Note: the per-worker value is not a secret — every ObjectId in your HTML"
    puts "   leaks it, so treat the worker multiplier as a convenience, not a defence.\n\n"
  end
end
