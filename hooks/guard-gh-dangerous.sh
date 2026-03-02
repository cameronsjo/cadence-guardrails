#!/usr/bin/env bash
# guard-gh-dangerous.sh — Block irreversible gh CLI operations
#
# PreToolUse hook for Bash. Blocks commands that cause permanent data loss
# regardless of repo ownership. guard-gh-write.sh allows writes to your own
# repos — this hook catches the subset that should never be automated.
#
# Blocked operations:
#   - gh repo delete (permanent, no undo)
#
# Config: None required — unconditional block.

set -euo pipefail

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null || echo "")

# Quick exit: no gh in command
echo "$COMMAND" | grep -q '\bgh\b' || exit 0

# Strip quoted strings to avoid false positives from prose in --body, --title, etc.
STRIPPED=$(echo "$COMMAND" | sed -E "s/\"[^\"]*\"//g; s/'[^']*'//g")

# --- gh repo delete ---

# Pass 1: check stripped command (direct invocations, filters prose false positives)
if echo "$STRIPPED" | grep -qE '\bgh[[:space:]]+repo[[:space:]]+delete\b'; then
  echo "🚫 git-guardrails: gh repo delete is blocked" >&2
  echo "   Repository deletion is irreversible — delete manually via github.com" >&2
  exit 2
fi

# Pass 2: check raw command inside exec wrappers (bash -c "gh repo delete ...")
# Quote-stripping removes the inner command, so check raw when an exec wrapper is present
if echo "$STRIPPED" | grep -qE '\b(bash|sh|zsh)[[:space:]]+-c\b'; then
  if echo "$COMMAND" | grep -qE '\bgh[[:space:]]+repo[[:space:]]+delete\b'; then
    echo "🚫 git-guardrails: gh repo delete is blocked" >&2
    echo "   Repository deletion is irreversible — delete manually via github.com" >&2
    exit 2
  fi
fi

exit 0
