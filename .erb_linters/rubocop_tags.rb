# frozen_string_literal: true

module ERBLint
  module Linters
    # The Rubocop linter, also checking the conditions of <% if %>, <% unless %> and <% elsif %> tags. Rubocop checks each
    # tag's Ruby on its own and skips what doesn't parse, as these don't without their end, so it closes them first
    # (elsif becomes an if padded to the same length, so columns stay put)
    # Remove it, and enable Rubocop again, if erb_lint fixes this: https://github.com/Shopify/erb_lint/issues/332
    class RubocopTags < Rubocop
      include LinterRegistry

      self.config_schema = Rubocop::ConfigSchema

      CONDITION = /\A(?<indent>[[:blank:]]*)(?<keyword>if|unless|elsif)\b(?<rest>.*)\z/m

      private

      def rubocop_processed_source(content, filename)
        source = super
        return source if source.valid_syntax?

        match = CONDITION.match(content)
        return source unless match

        keyword = match[:keyword] == 'elsif' ? 'if   ' : match[:keyword]
        super("#{match[:indent]}#{keyword}#{match[:rest]}\n#{match[:indent]}  nil\n#{match[:indent]}end", filename)
      end
    end
  end
end
