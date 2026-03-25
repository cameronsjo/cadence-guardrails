#!/usr/bin/env bash
# Dispatch to cadence-hooks binary.
# Checks plugin data dir first, then PATH. Fails open if not found (ADR 0008).
# Usage: run-cadence-hooks.sh <subcommand> [args...]
set -euo pipefail

BINARY="${CLAUDE_PLUGIN_DATA:-}/bin/cadence-hooks"

if [ ! -x "$BINARY" ]; then
  BINARY=$(command -v cadence-hooks 2>/dev/null || true)
fi

if [ -z "$BINARY" ]; then
  exit 0
fi

exec "$BINARY" "$@"
