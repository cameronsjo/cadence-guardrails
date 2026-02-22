#!/usr/bin/env bash
# guard-gh-write.sh — Thin shim delegating to Node.js bundle
#
# PreToolUse hook for Bash. The actual logic lives in guard-gh-write.bundle.js.
# This shim exists because hooks.json registers .sh files as hook commands.
# stdin passes through automatically via exec.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE="$SCRIPT_DIR/guard-gh-write.bundle.js"

# Fail-safe: if node or bundle unavailable, block (don't silently allow)
if ! command -v node &>/dev/null; then
  echo "🚫 git-guardrails: node not found — cannot run gh write guard" >&2
  exit 2
fi

if [ ! -f "$BUNDLE" ]; then
  echo "🚫 git-guardrails: guard-gh-write.bundle.js not found — run 'pnpm run build'" >&2
  exit 2
fi

exec node "$BUNDLE"
