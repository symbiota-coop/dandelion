# Helpers for the test files that check what's reported to Sentry (test/integrations/atproto_events,
# test/payments/exchange_rates)
module ErrorReportingHelpers
  # The exceptions ErrorReporting would send to Sentry while the block runs
  def reported_exceptions(&)
    reported = []
    ErrorReporting.stub(:capture_exception, ->(exception, **) { reported << exception }, &)
    reported
  end
end
