# frozen_string_literal: true

module ERBLint
  module Linters
    # The Rubocop linter, with two changes:
    # - It also checks the conditions of <% if %>, <% unless %> and <% elsif %> tags. Rubocop checks each tag's Ruby on its
    #   own and skips what doesn't parse, as these don't without their end, so it closes them first (elsif becomes an if
    #   padded to the same length, so columns stay put). https://github.com/Shopify/erb_lint/issues/332
    # - It builds RuboCop's team of cops once, not for every tag, which made it most of erb_lint's time (the cops start
    #   afresh on each source they investigate, so one team serves them all)
    class RubocopTags < Rubocop
      include LinterRegistry

      self.config_schema = Rubocop::ConfigSchema

      CONDITION = /\A(?<indent>[[:blank:]]*)(?<keyword>if|unless|elsif)\b(?<rest>.*)\z/m

      private

      def build_team
        @build_team ||= super
      end

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
