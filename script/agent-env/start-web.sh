#!/usr/bin/env bash
# Starts Puma in the background, logging to log/web.log, for environments with no terminal to keep it running in.
# Does nothing if port 3000 is answering or foreman is already starting it (Puma takes about 20 seconds to boot).
set -euo pipefail

if ! (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null && ! pgrep -f 'foreman: main' >/dev/null; then
  mkdir -p log
  setsid nohup foreman start -e .env web >> log/web.log 2>&1 < /dev/null &
fi
