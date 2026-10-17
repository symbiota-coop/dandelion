# frozen_string_literal: true

module ERBLint
  module Linters
    # CDN files load with cdn_tag, which adds the hash in frontend/integrity.json as their integrity attribute, so the
    # browser won't run a file that's changed, and an npm package's file at the version frontend/package.json names, so
    # versions live in one place (AGENTS.md, Dependencies)
    class CdnTags < Linter
      include LinterRegistry

      # A script or stylesheet from a CDN, by a path on it (a preconnect link names the host alone)
      BARE_TAG = %r{<(?:script|link)\b[^>]*?\b(?:src|href)=["']https://(?:cdn\.jsdelivr\.net|unpkg\.com|cdnjs\.cloudflare\.com)/}
      CONFIG = File.expand_path('../config/frontend_dependencies.rb', __dir__)

      def run(processed_source)
        source = processed_source.file_content
        source.scan(BARE_TAG) do
          match = Regexp.last_match
          offense(processed_source, match.begin(0)...match.end(0), 'Load CDN files with `cdn_tag`, which adds the hash the browser checks them against.')
        end
        source.scan(frontend::FRONTEND_CDN_TAG) do
          match = Regexp.last_match
          check_cdn_tag(processed_source, match)
        end
      end

      private

      def check_cdn_tag(processed_source, match)
        name, file = match.captures
        range = match.begin(1)...match.end(file ? 2 : 1)
        if file && !frontend::FRONTEND_VERSIONS.key?(name)
          offense(processed_source, range, "#{name} isn't in frontend/package.json: add it there at an exact version.")
        elsif !file && name.match?(%r{\Ahttps://cdn\.jsdelivr\.net/npm/})
          offense(processed_source, range, "Name the package and file (`cdn_tag 'package', 'path/file.js'`), so its version comes from frontend/package.json.")
        elsif !frontend::FRONTEND_INTEGRITY.key?(url = file ? frontend::FRONTEND_NPM_URL.call(name, file) : name)
          offense(processed_source, range, "#{url} has no hash in frontend/integrity.json: run `rake frontend:integrity`.")
        end
      end

      def offense(processed_source, range, message)
        add_offense(processed_source.to_source_range(range), "CdnTags: #{message}")
      end

      # config/frontend_dependencies.rb, in a module of its own, with its path, so __dir__ works and nothing leaks into
      # the linter's process
      def frontend
        @frontend ||= Module.new.tap { |m| m.module_eval(File.read(CONFIG), CONFIG) }
      end
    end
  end
end
