#!/usr/bin/env bash
set -euo pipefail

BUNDLER_VERSION="$(grep -A1 '^BUNDLED WITH' Gemfile.lock | tail -1 | tr -d ' ')"
gem list -i bundler -v "$BUNDLER_VERSION" >/dev/null || gem install bundler -v "$BUNDLER_VERSION"
command -v foreman >/dev/null || gem install foreman

bundle config set build.nokogiri "--use-system-libraries"

# Bundler's cached local git clone can become invalid under Docker/OverlayFS
# when copying git-sourced gems from cache/bundler/git into bundler/gems.
# Clear both sides and retry after a failed attempt.
clear_bundler_git_checkouts() {
  rm -rf "${BUNDLE_PATH:-/usr/local/bundle}"/ruby/*/cache/bundler/git 2>/dev/null || true
  rm -rf "${BUNDLE_PATH:-/usr/local/bundle}"/ruby/*/bundler/gems/* 2>/dev/null || true
}

# Skip the reinstall (and the git cache wipe) when everything is already installed
if bundle check >/dev/null 2>&1; then
  echo "Gems already installed"
else
  clear_bundler_git_checkouts

  for attempt in 1 2 3; do
    if bundle install; then
      break
    fi
    if [ "$attempt" -eq 3 ]; then
      exit 1
    fi
    clear_bundler_git_checkouts
  done
fi

if [ ! -f .env ]; then
  cp .env.example .env
fi

if [ ! -f .env.test ]; then
  cp .env.test.example .env.test
fi

mkdir -p app/assets/dragonfly capybara log tmp
