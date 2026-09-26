#!/usr/bin/env bash
# System packages and MongoDB for cloud agent environments (Cursor, Claude Code).
# Run as root or with passwordless sudo.
set -euo pipefail

MONGODB_VERSION=8.2.6

SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

export DEBIAN_FRONTEND=noninteractive
$SUDO apt-get update -qq
$SUDO apt-get install -y --no-install-recommends \
  autoconf \
  automake \
  build-essential \
  ca-certificates \
  chromium \
  curl \
  fonts-liberation \
  git \
  imagemagick \
  libffi-dev \
  libssl-dev \
  libtool \
  libxml2-dev \
  libxslt1-dev \
  libyaml-dev \
  libzstd-dev \
  pkg-config \
  sudo \
  tzdata \
  zlib1g-dev
$SUDO rm -rf /var/lib/apt/lists/*

if ! command -v mongod >/dev/null; then
  . /etc/os-release
  case "$(uname -m)" in
    x86_64) arch=x86_64 ;;
    aarch64|arm64) arch=aarch64 ;;
    *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
  esac
  if [ "$ID" = "debian" ] && [ "$arch" = "x86_64" ]; then
    distro=debian12
  else
    distro=ubuntu2204
  fi
  curl -fsSL "https://fastdl.mongodb.org/linux/mongodb-linux-${arch}-${distro}-${MONGODB_VERSION}.tgz" -o /tmp/mongodb.tgz
  mkdir -p /tmp/mongodb
  tar -xzf /tmp/mongodb.tgz -C /tmp/mongodb --strip-components=1
  $SUDO cp /tmp/mongodb/bin/mongod /tmp/mongodb/bin/mongos /usr/local/bin/
  rm -rf /tmp/mongodb /tmp/mongodb.tgz
fi
