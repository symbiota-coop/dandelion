#!/usr/bin/env bash
set -euo pipefail

sudo mkdir -p /data/db
sudo chown -R "$(id -u):$(id -g)" /data/db

if ! pgrep -x mongod >/dev/null; then
  mongod --fork --logpath /tmp/mongod.log --dbpath /data/db --bind_ip 127.0.0.1
fi
