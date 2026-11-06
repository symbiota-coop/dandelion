# frozen_string_literal: true

module ERBLint
  module Linters
    # Fields for an amount of money show its currency: the form builder's currency_block puts the symbol in an input
    # group before the number (money_symbol(currency)), where number_block leaves a bare number. Checks number_block on
    # fields named for money; one whose currency is chosen beside it (a refund payment's) says so in a disable comment
    class MoneyFields < Linter
      include LinterRegistry

      MESSAGE = 'MoneyFields: An amount of money shows its currency: use `f.currency_block :field, ' \
                'money_symbol: money_symbol(currency)`, not `number_block`.'

      MONEY = /\bnumber_block[ (]+:(?:\w+_)?(?:cost|price|amount|budget|fee|donation|contribution|paid)\b/

      def run(processed_source)
        processed_source.file_content.scan(MONEY) do
          match = Regexp.last_match
          add_offense(processed_source.to_source_range(match.begin(0)...match.end(0)), MESSAGE)
        end
      end
    end
  end
end
