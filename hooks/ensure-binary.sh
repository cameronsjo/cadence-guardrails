#!/usr/bin/env bash
# Auto-install cadence-hooks binary to plugin data directory.
# Runs at SessionStart. Downloads from GitHub release if missing or outdated.
# All failure paths exit 0 (fail open per ADR 0008).
set -euo pipefail

# Fail open if required env vars are not set
if [ -z "${CLAUDE_PLUGIN_DATA:-}" ] || [ -z "${CLAUDE_PLUGIN_ROOT:-}" ]; then
  exit 0
fi

BIN_DIR="${CLAUDE_PLUGIN_DATA}/bin"
BINARY="${BIN_DIR}/cadence-hooks"
EXPECTED=$(cat "${CLAUDE_PLUGIN_ROOT}/hooks/binary-version.txt" 2>/dev/null || echo "unknown")
if [ "$EXPECTED" = "unknown" ]; then
  echo "cadence-hooks: binary-version.txt missing or unreadable" >&2
  exit 0
fi

# Already installed and correct version?
if [ -x "$BINARY" ]; then
  CURRENT=$("$BINARY" --version 2>/dev/null | awk '{print $2}' || echo "unknown")
  [ "$EXPECTED" = "$CURRENT" ] && exit 0
fi

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$OS-$ARCH" in
  darwin-arm64)   PLATFORM="macos-aarch64" ;;
  darwin-x86_64)  PLATFORM="macos-x86_64" ;;
  linux-x86_64)   PLATFORM="linux-x86_64" ;;
  linux-aarch64)  PLATFORM="linux-aarch64" ;;
  linux-arm64)    PLATFORM="linux-aarch64" ;;
  *) echo "cadence-hooks: unsupported platform $OS-$ARCH" >&2; exit 0 ;;
esac

# Private repo — requires gh CLI
if ! command -v gh >/dev/null 2>&1; then
  echo "cadence-hooks: gh CLI required for auto-install (private repo)" >&2
  exit 0
fi

# Install in a subshell so failures don't propagate under set -e
if ! (
  TMP_DIR=$(mktemp -d)
  trap 'rm -rf "$TMP_DIR"' EXIT
  ARCHIVE="cadence-hooks-v${EXPECTED}-${PLATFORM}.tar.gz"

  gh release download "v${EXPECTED}" \
    --repo cameronsjo/cadence-hooks \
    --pattern "$ARCHIVE" \
    --dir "$TMP_DIR" \
    --clobber 2>/dev/null

  mkdir -p "$BIN_DIR"
  tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "$BIN_DIR"
  chmod +x "$BINARY"
); then
  echo "cadence-hooks: install failed" >&2
  exit 0
fi

echo "cadence-hooks ${EXPECTED} installed" >&2
