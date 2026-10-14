#!/usr/bin/env bash
# Sets up Claude Code on the web sessions with script/agent-env, as .cursor/ does.
# No-op outside the cloud environment.
set -euo pipefail
[ "${CLAUDE_CODE_REMOTE:-}" = "true" ] || exit 0

cd "$(dirname "$0")/.."

if ! command -v mongod >/dev/null || [ -z "$(bash script/agent-env/browser-path.sh)" ]; then
  bash script/agent-env/system-deps.sh
fi
BROWSER_PATH="$(bash script/agent-env/browser-path.sh)"

RUBY_PREFIX="$(bash script/agent-env/ruby.sh)"
[ -z "$RUBY_PREFIX" ] || export PATH="$RUBY_PREFIX/bin:$PATH"

NODE_PREFIX="$(bash script/agent-env/node.sh)"
[ -z "$NODE_PREFIX" ] || export PATH="$NODE_PREFIX/bin:$PATH"

# Chromium ignores the system CA store, so trust the agent proxy's CA in its NSS store, or every CDN request fails
PROXY_CA=/root/.ccr/agent-proxy-ca.crt
if [ -f "$PROXY_CA" ]; then
  command -v certutil >/dev/null || { apt-get update -qq && apt-get install -y -qq --no-install-recommends libnss3-tools; } >/dev/null
  mkdir -p "$HOME/.pki/nssdb"
  [ -f "$HOME/.pki/nssdb/cert9.db" ] || certutil -d "sql:$HOME/.pki/nssdb" -N --empty-password
  certutil -d "sql:$HOME/.pki/nssdb" -L -n ccr-agent-proxy >/dev/null 2>&1 \
    || certutil -d "sql:$HOME/.pki/nssdb" -A -t "C,," -n ccr-agent-proxy -i "$PROXY_CA"
fi

# Persist to the agent's shell, which doesn't inherit this script's environment
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export BROWSER_PATH=$BROWSER_PATH"
    if [ -n "$RUBY_PREFIX" ]; then
      echo "export PATH=\"$RUBY_PREFIX/bin:\$PATH\""
    fi
    if [ -n "$NODE_PREFIX" ]; then
      echo "export PATH=\"$NODE_PREFIX/bin:\$PATH\""
    fi
  } >> "$CLAUDE_ENV_FILE"
fi

bash script/agent-env/install.sh
bash script/agent-env/start-services.sh
bash script/agent-env/start-web.sh
