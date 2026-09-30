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

# Prebuilt Ruby from ruby/ruby-builder (as used by ruby/setup-ruby), installed at the prefix it was built for
RUBY_PREFIX=""
if [ "$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)" != "$RUBY_VERSION" ]; then
  . /etc/os-release
  case "$(uname -m)" in
    x86_64) ruby_arch=x64 ;;
    aarch64|arm64) ruby_arch=arm64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  case "${ID}-${VERSION_ID}" in
    ubuntu-22.04|ubuntu-24.04) ;;
    *) echo "No prebuilt Ruby for ${ID} ${VERSION_ID}" >&2; exit 1 ;;
  esac
  RUBY_PREFIX="/opt/hostedtoolcache/Ruby/${RUBY_VERSION}/${ruby_arch}"
  if [ ! -x "$RUBY_PREFIX/bin/ruby" ]; then
    SUDO=""
    [ "$(id -u)" -ne 0 ] && SUDO="sudo"
    $SUDO mkdir -p "$(dirname "$RUBY_PREFIX")"
    curl -fsSL "https://github.com/ruby/ruby-builder/releases/download/ruby-${RUBY_VERSION}/ruby-${RUBY_VERSION}-ubuntu-${VERSION_ID}-${ruby_arch}.tar.gz" \
      | $SUDO tar -xz -C "$(dirname "$RUBY_PREFIX")"
    $SUDO chown -R "$(id -u):$(id -g)" "$RUBY_PREFIX"
  fi
  export PATH="$RUBY_PREFIX/bin:$PATH"
fi

# Chromium ignores the system CA store, so trust the agent proxy's CA in its NSS store, or every CDN request fails
PROXY_CA=/root/.ccr/agent-proxy-ca.crt
if [ -f "$PROXY_CA" ]; then
  command -v certutil >/dev/null || { apt-get update -qq && apt-get install -y -qq --no-install-recommends libnss3-tools; } >/dev/null
  mkdir -p "$HOME/.pki/nssdb"
  [ -f "$HOME/.pki/nssdb/cert9.db" ] || certutil -d "sql:$HOME/.pki/nssdb" -N --empty-password
  certutil -d "sql:$HOME/.pki/nssdb" -L -n ccr-agent-proxy >/dev/null 2>&1 \
    || certutil -d "sql:$HOME/.pki/nssdb" -A -t "C,," -n ccr-agent-proxy -i "$PROXY_CA"
fi

gem list -i bundler -v "$BUNDLER_VERSION" >/dev/null || gem install bundler -v "$BUNDLER_VERSION"
command -v foreman >/dev/null || gem install foreman

# Persist to the agent's shell, which doesn't inherit this script's environment
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export BROWSER_PATH=$BROWSER_PATH"
    if [ -n "$RUBY_PREFIX" ]; then
      echo "export PATH=\"$RUBY_PREFIX/bin:\$PATH\""
    fi
  } >> "$CLAUDE_ENV_FILE"
fi

bash script/agent-env/install.sh
bash script/agent-env/start-services.sh

# Keep Puma running like Cursor's web terminal, detached so the hook can finish
if ! (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null; then
  mkdir -p log
  setsid nohup foreman start -e .env web >> log/web.log 2>&1 < /dev/null &
fi
