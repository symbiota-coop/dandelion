#!/usr/bin/env bash
# Prints the path of the Chromium for BROWSER_PATH, or nothing if there isn't one.
# Prefers the Playwright Chromium preinstalled in some images, as Ubuntu's apt chromium is a snap stub.
set -euo pipefail

if [ -x /opt/pw-browsers/chromium ]; then
  echo /opt/pw-browsers/chromium
else
  command -v chromium || true
fi
