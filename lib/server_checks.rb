# What the server checks pages (/stats/atlas, /stats/caches, /stats/images) share: how long each check takes, and, for
# a set of pass-or-fail checks (AtlasChecks, ImageChecks, which extend this), each one's result as a Check, a check
# that raises failing with its error rather than hiding the checks after it. app/views/stats/_checks.erb shows them
module ServerChecks
  Check = Struct.new(:group, :name, :ok, :detail, :ms, keyword_init: true)

  # The block's result, and how long it took in milliseconds
  def self.timed
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = yield
    [result, ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round]
  end

  # A Check from a block giving [ok, detail]
  def check(group, name)
    (ok, detail), ms = ServerChecks.timed do
      yield
    rescue StandardError => e
      [false, "#{e.class}: #{e.message.truncate(200)}"]
    end
    Check.new(group:, name:, ok:, detail:, ms:)
  end
end
