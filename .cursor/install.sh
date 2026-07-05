#!/usr/bin/env bash
set -euo pipefail

bundle config set build.nokogiri "--use-system-libraries"

# Bundler's cached local git clone can become invalid under Docker/OverlayFS
# when copying git-sourced gems from cache/bundler/git into bundler/gems.
# Clear both sides and retry after a failed attempt.
clear_bundler_git_checkouts() {
  rm -rf "${BUNDLE_PATH:-/usr/local/bundle}"/ruby/*/cache/bundler/git 2>/dev/null || true
  rm -rf "${BUNDLE_PATH:-/usr/local/bundle}"/ruby/*/bundler/gems/* 2>/dev/null || true
}

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

if [ ! -f .env ]; then
  cp .env.example .env
fi

if [ ! -f .env.test ]; then
  cp .env.test.example .env.test
fi

mkdir -p app/assets/dragonfly capybara log tmp
