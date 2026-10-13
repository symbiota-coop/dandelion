# frozen_string_literal: true

module ERBLint
  module Linters
    # ErbSafety without better_html's script type check, whose list of types is fixed:
    # the AllowedScriptType linter checks script types against our own list instead
    class SafeErb < ErbSafety
      include LinterRegistry

      self.config_schema = ErbSafety::ConfigSchema

      private

      def tester_classes
        super - [BetterHtml::TestHelper::SafeErb::AllowedScriptType]
      end
    end
  end
end
