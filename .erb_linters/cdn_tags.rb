# frozen_string_literal: true

module ERBLint
  module Linters
    # CDN files load with cdn_tag, which adds the hash in config/frontend_integrity.rb as their integrity attribute, so the
    # browser won't run a file that's changed (AGENTS.md, Dependencies)
    class CdnTags < Linter
      include LinterRegistry

      # A script or stylesheet from a CDN, by a path on it (a preconnect link names the host alone)
      BARE_TAG = %r{<(?:script|link)\b[^>]*?\b(?:src|href)=["']https://(?:cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com)/}
      CDN_TAG = /cdn_tag[ (]+['"]([^'"]+)['"]/
      INTEGRITY_FILE = File.expand_path('../config/frontend_integrity.rb', __dir__)

      def run(processed_source)
        source = processed_source.file_content
        source.scan(BARE_TAG) do
          match = Regexp.last_match
          add_offense(processed_source.to_source_range(match.begin(0)...match.end(0)),
                      'CdnTags: Load CDN files with `cdn_tag`, which adds the hash the browser checks them against.')
        end
        source.scan(CDN_TAG) do
          match = Regexp.last_match
          next if integrity.key?(match[1])

          add_offense(processed_source.to_source_range(match.begin(1)...match.end(1)),
                      "CdnTags: #{match[1]} has no hash in config/frontend_integrity.rb: run `rake frontend:integrity`.")
        end
      end

      private

      def integrity
        @integrity ||= Module.new.tap { |m| m.module_eval(File.read(INTEGRITY_FILE)) }::FRONTEND_INTEGRITY
      end
    end
  end
end
