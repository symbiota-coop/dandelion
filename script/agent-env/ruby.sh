#!/usr/bin/env bash
# Installs the Gemfile's Ruby, prebuilt by ruby/ruby-builder (as used by ruby/setup-ruby), for images that don't have it.
# Prints the prefix to put on PATH ("$prefix/bin"), or nothing when the Ruby on PATH is already the right one.
set -euo pipefail

RUBY_VERSION="$(sed -nE "s/^ruby '([^']+)'.*/\1/p" Gemfile)"

[ "$(ruby -e 'print RUBY_VERSION' 2>/dev/null || true)" = "$RUBY_VERSION" ] && exit 0

# shellcheck source=/dev/null # the image's, so not ours to check
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

# Installed at the prefix it was built for
RUBY_PREFIX="/opt/hostedtoolcache/Ruby/${RUBY_VERSION}/${ruby_arch}"
if [ ! -x "$RUBY_PREFIX/bin/ruby" ]; then
  SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  $SUDO mkdir -p "$(dirname "$RUBY_PREFIX")"
  curl -fsSL "https://github.com/ruby/ruby-builder/releases/download/ruby-${RUBY_VERSION}/ruby-${RUBY_VERSION}-ubuntu-${VERSION_ID}-${ruby_arch}.tar.gz" \
    | $SUDO tar -xz -C "$(dirname "$RUBY_PREFIX")"
  $SUDO chown -R "$(id -u):$(id -g)" "$RUBY_PREFIX"
fi
echo "$RUBY_PREFIX"
