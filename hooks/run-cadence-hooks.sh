#!/usr/bin/env bash
# Dispatch to cadence-hooks binary on PATH. Fails open if not found (ADR 0008).
# Usage: run-cadence-hooks.sh <subcommand> [args...]
set -euo pipefail

BINARY=$(command -v cadence-hooks 2>/dev/null || true)

if [ -z "$BINARY" ]; then
  exit 0
fi

exec "$BINARY" "$@"
