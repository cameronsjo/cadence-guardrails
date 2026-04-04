#!/usr/bin/env bash
# Deferred cadence-hooks brew upgrade after push to main.
# Designed to run via CronCreate ~4 minutes after push.
#
# Watches the latest Beta Release CI run (if still in-progress),
# then upgrades cadence-hooks-beta via Homebrew.
# All failures are non-blocking (exit 0) — this is informational.
set -euo pipefail

REPO="cameronsjo/cadence-hooks"
FORMULA="cameronsjo/tap/cadence-hooks-beta"
WORKFLOW="Beta Release"

# Pre-flight checks
command -v gh >/dev/null 2>&1 || { echo "gh CLI not found — skipping upgrade" >&2; exit 0; }
command -v brew >/dev/null 2>&1 || { echo "brew not found — skipping upgrade" >&2; exit 0; }

# Find latest workflow run
RUN_JSON=$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --limit 1 \
  --json databaseId,status 2>/dev/null || echo "[]")
RUN_STATUS=$(echo "$RUN_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['status'] if d else 'none')" 2>/dev/null || echo "none")
RUN_ID=$(echo "$RUN_JSON" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['databaseId'] if d else '')" 2>/dev/null || echo "")

if [ "$RUN_STATUS" = "in_progress" ] || [ "$RUN_STATUS" = "queued" ]; then
    echo "Waiting for CI run $RUN_ID to complete..."
    timeout 300 gh run watch "$RUN_ID" --repo "$REPO" --exit-status 2>/dev/null || {
        echo "CI run did not complete successfully within 5 minutes — skipping upgrade" >&2
        exit 0
    }
fi

# Small delay for Homebrew tap dispatch to propagate
sleep 15

# Capture before version
BEFORE=$(brew info "$FORMULA" --json=v2 2>/dev/null | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
installed = d['formulae'][0].get('installed', [])
print(installed[0]['version'] if installed else 'none')
" 2>/dev/null || echo "unknown")

# Update and upgrade
brew update --quiet 2>/dev/null || true
brew upgrade "$FORMULA" 2>/dev/null || true

# Capture after version
AFTER=$(brew info "$FORMULA" --json=v2 2>/dev/null | \
  python3 -c "
import sys, json
d = json.load(sys.stdin)
installed = d['formulae'][0].get('installed', [])
print(installed[0]['version'] if installed else 'none')
" 2>/dev/null || echo "unknown")

if [ "$BEFORE" = "$AFTER" ]; then
    echo "cadence-hooks already at $AFTER (no upgrade available yet)"
else
    echo "cadence-hooks upgraded: $BEFORE -> $AFTER"
fi
