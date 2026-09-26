#!/usr/bin/env bash
# Sets up Claude Code on the web sessions, sharing script/agent-env with .cursor/.
# No-op outside the cloud environment.
set -euo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "$(dirname "$0")/.."

RUBY_VERSION=3.4.7
BUNDLER_VERSION=2.4.19

# Prefer the Playwright Chromium preinstalled in the image; Ubuntu's apt chromium is a snap stub
find_browser() {
  if [ -x /opt/pw-browsers/chromium ]; then
    echo /opt/pw-browsers/chromium
  else
    command -v chromium || true
  fi
}

if ! command -v mongod >/dev/null || [ -z "$(find_browser)" ]; then
  bash script/agent-env/system-deps.sh
fi
BROWSER_PATH="$(find_browser)"

if [ "$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)" != "$RUBY_VERSION" ]; then
  if command -v rbenv >/dev/null; then
    rbenv install -s "$RUBY_VERSION"
    export RBENV_VERSION="$RUBY_VERSION"
    export PATH="$(rbenv root)/shims:$PATH"
  else
    echo "Ruby $RUBY_VERSION not found and rbenv unavailable" >&2
    exit 1
  fi
fi

gem list -i bundler -v "$BUNDLER_VERSION" >/dev/null || gem install bundler -v "$BUNDLER_VERSION"
command -v foreman >/dev/null || gem install foreman

# Persist to the agent's shell, which doesn't inherit this script's environment
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export BROWSER_PATH=$BROWSER_PATH"
    if [ -n "${RBENV_VERSION:-}" ]; then
      echo "export RBENV_VERSION=$RBENV_VERSION"
      echo "export PATH=\"$(rbenv root)/shims:\$PATH\""
    fi
  } >> "$CLAUDE_ENV_FILE"
fi

bash script/agent-env/install.sh
bash script/agent-env/start-services.sh
