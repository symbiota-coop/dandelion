#!/usr/bin/env bash
# Installs zizmor, the GitHub Actions linter script/lint runs, into tmp/zizmor at the version and hashes in zizmor.txt.
# A no-op when that version is already there
set -euo pipefail

cd "$(dirname "$0")/../.."
ZIZMOR_VERSION="$(grep -oE '^zizmor==[0-9.]+' script/agent-env/zizmor.txt | cut -d= -f3)"

[ "$(tmp/zizmor/bin/zizmor --version 2>/dev/null || true)" = "zizmor $ZIZMOR_VERSION" ] && exit 0

rm -rf tmp/zizmor
# A wheel (zizmor is a Rust binary with no dependencies), never the source, which would need Rust to build
python3 -m pip install --quiet --disable-pip-version-check --root-user-action ignore --no-deps --only-binary :all: --require-hashes \
  --target tmp/zizmor -r script/agent-env/zizmor.txt
tmp/zizmor/bin/zizmor --version
