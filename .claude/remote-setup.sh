#!/usr/bin/env bash
# Sets up Claude Code on the web sessions, sharing script/agent-env with .cursor/.
# No-op outside the cloud environment.
set -euo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "$(dirname "$0")/.."

RUBY_VERSION=3.4.7
BUNDLER_VERSION=2.4.19

if ! command -v mongod >/dev/null || ! command -v chromium >/dev/null; then
  bash script/agent-env/system-deps.sh
fi

if [ "$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)" != "$RUBY_VERSION" ]; then
  if command -v rbenv >/dev/null; then
    rbenv install -s "$RUBY_VERSION"
    rbenv local "$RUBY_VERSION"
    eval "$(rbenv init - bash)"
  else
    echo "Ruby $RUBY_VERSION not found and rbenv unavailable" >&2
    exit 1
  fi
fi

gem list -i bundler -v "$BUNDLER_VERSION" >/dev/null || gem install bundler -v "$BUNDLER_VERSION"
command -v foreman >/dev/null || gem install foreman

if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export BROWSER_PATH=$(command -v chromium)" >> "$CLAUDE_ENV_FILE"
fi

bash script/agent-env/install.sh
bash script/agent-env/start-services.sh
