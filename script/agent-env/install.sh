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

# ESLint and Stylelint (Node from node.sh). Linters only, so a failure warns rather than stopping the services that start after this
if ! command -v npm >/dev/null; then
  echo "WARNING: no npm, so ESLint and Stylelint aren't installed: run script/agent-env/node.sh, then npm ci" >&2
else
  for attempt in 1 2 3; do
    if npm ci --no-audit --no-fund; then
      break
    fi
    if [ "$attempt" -eq 3 ]; then
      echo "WARNING: npm ci failed, so ESLint and Stylelint aren't installed: run npm ci" >&2
    fi
  done
fi

# uv, whose uvx runs zizmor and actionlint (script/lint) on the GitHub Actions workflows and ShellCheck on the shell scripts. A linter only, so a failure warns
if ! command -v uvx >/dev/null; then
  SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  if ! curl -LsSf https://astral.sh/uv/0.13.1/install.sh | $SUDO env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh; then
    echo "WARNING: uv failed to install, so zizmor, actionlint and ShellCheck can't run: install uv (https://docs.astral.sh/uv/)" >&2
  fi
fi

# The pre-commit hook, which lints staged files with script/lint
git config core.hooksPath .githooks

if [ ! -f .env ]; then
  cp .env.example .env
fi

if [ ! -f .env.test ]; then
  cp .env.test.example .env.test
fi

mkdir -p app/assets/dragonfly capybara log tmp
