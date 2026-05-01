module ErrorReporting
  module_function

  def capture_exception(exception, context: nil, tags: nil)
    return if exception.nil?

    Sentry.with_scope do |scope|
      scope.set_context('additional', context) if context.present?
      scope.set_tags(tags) if tags.present?
      Sentry.capture_exception(exception)
    end
  end
end
