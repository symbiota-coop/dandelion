#!/usr/bin/env bash
# Starts Puma in the background, logging to log/web.log, for environments with no terminal to keep it running in.
# Does nothing if port 3000 is answering or it's already starting (Puma takes about 20 seconds to boot).
set -euo pipefail

if ! (exec 3<>/dev/tcp/127.0.0.1/3000) 2>/dev/null && ! pgrep -f 'puma -C config/puma.rb' >/dev/null; then
  mkdir -p log
  setsid nohup script/env bundle exec puma -C config/puma.rb >> log/web.log 2>&1 < /dev/null &
fi
