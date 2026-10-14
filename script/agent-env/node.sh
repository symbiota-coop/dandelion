#!/usr/bin/env bash
# Installs the Node in .nvmrc (which CI's setup-node also reads), for images without its major.
# Prints the prefix to put on PATH ("$prefix/bin"), or nothing when the Node on PATH already has that major.
set -euo pipefail

cd "$(dirname "$0")/../.."
NODE_VERSION="$(tr -d '[:space:]v' < .nvmrc)"

[ "$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true)" = "${NODE_VERSION%%.*}" ] && exit 0

case "$(uname -m)" in
  x86_64) node_arch=x64 ;;
  aarch64|arm64) node_arch=arm64 ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

# A prefix of its own, so it never overwrites a Node the image already has
NODE_PREFIX="/opt/hostedtoolcache/node/${NODE_VERSION}/${node_arch}"
if [ ! -x "$NODE_PREFIX/bin/node" ]; then
  SUDO=""
  [ "$(id -u)" -ne 0 ] && SUDO="sudo"
  tarball="node-v${NODE_VERSION}-linux-${node_arch}.tar.xz"
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/${tarball}" -o "$tmp/$tarball"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" -o "$tmp/SHASUMS256.txt"
  (cd "$tmp" && grep " ${tarball}\$" SHASUMS256.txt | sha256sum -c --quiet -)
  $SUDO mkdir -p "$NODE_PREFIX"
  $SUDO tar -xJf "$tmp/$tarball" -C "$NODE_PREFIX" --strip-components=1
  $SUDO chown -R "$(id -u):$(id -g)" "$NODE_PREFIX"
fi
echo "$NODE_PREFIX"
