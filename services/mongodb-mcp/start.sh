#!/usr/bin/env bash
set -euo pipefail

export MDB_MCP_TRANSPORT="${MDB_MCP_TRANSPORT:-http}"
export MDB_MCP_HTTP_HOST="${MDB_MCP_HTTP_HOST:-0.0.0.0}"
export MDB_MCP_HTTP_PORT="${PORT:-3000}"
export MDB_MCP_READ_ONLY="${MDB_MCP_READ_ONLY:-true}"
export MDB_MCP_LOGGERS="${MDB_MCP_LOGGERS:-stderr}"
export MDB_MCP_HTTP_HEADERS="{\"Authorization\":\"Bearer ${MONGODB_MCP_TOKEN:?MONGODB_MCP_TOKEN must be set}\"}"

exec ./node_modules/.bin/mongodb-mcp-server
