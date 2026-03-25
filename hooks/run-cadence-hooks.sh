#!/usr/bin/env bash
# Dispatch to cadence-hooks binary.
# Checks plugin data dir first, then PATH. Fails open if not found (ADR 0008).
# Usage: run-cadence-hooks.sh <subcommand> [args...]
set -euo pipefail

BINARY=""

# Check plugin data dir first
if [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && [ -x "${CLAUDE_PLUGIN_DATA}/bin/cadence-hooks" ]; then
  BINARY="${CLAUDE_PLUGIN_DATA}/bin/cadence-hooks"
fi

# Fall back to PATH
if [ -z "$BINARY" ]; then
  BINARY=$(command -v cadence-hooks 2>/dev/null || true)
fi

# Fail open if not found
if [ -z "$BINARY" ]; then
  exit 0
fi

exec "$BINARY" "$@"
