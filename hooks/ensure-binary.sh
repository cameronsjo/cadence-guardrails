#!/usr/bin/env bash
# Auto-install cadence-hooks binary to plugin data directory.
# Runs at SessionStart. Downloads from GitHub release if missing or outdated.
# All failure paths exit 0 (fail open per ADR 0008).
set -euo pipefail

BIN_DIR="${CLAUDE_PLUGIN_DATA}/bin"
BINARY="${BIN_DIR}/cadence-hooks"
EXPECTED=$(cat "${CLAUDE_PLUGIN_ROOT}/hooks/binary-version.txt" 2>/dev/null || echo "unknown")

# Already installed and correct version?
if [ -x "$BINARY" ]; then
  CURRENT=$("$BINARY" --version 2>/dev/null | awk '{print $2}' || echo "unknown")
  [ "$EXPECTED" = "$CURRENT" ] && exit 0
fi

# Detect platform
OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ARCH=$(uname -m)
case "$OS-$ARCH" in
  darwin-arm64)  PLATFORM="macos-aarch64" ;;
  darwin-x86_64) PLATFORM="macos-x86_64" ;;
  linux-x86_64)  PLATFORM="linux-x86_64" ;;
  linux-aarch64) PLATFORM="linux-aarch64" ;;
  *) echo "cadence-hooks: unsupported platform $OS-$ARCH" >&2; exit 0 ;;
esac

mkdir -p "$BIN_DIR"

# Private repo — requires gh CLI
if ! command -v gh >/dev/null 2>&1; then
  echo "cadence-hooks: gh CLI required for auto-install (private repo)" >&2
  exit 0
fi

ARCHIVE="cadence-hooks-v${EXPECTED}-${PLATFORM}.tar.gz"

gh release download "v${EXPECTED}" \
  --repo cameronsjo/cadence-hooks \
  --pattern "$ARCHIVE" \
  --dir /tmp \
  --clobber 2>/dev/null || { echo "cadence-hooks: download failed" >&2; exit 0; }

tar -xzf "/tmp/${ARCHIVE}" -C "$BIN_DIR"
chmod +x "$BINARY"
rm -f "/tmp/${ARCHIVE}"

echo "cadence-hooks ${EXPECTED} installed" >&2
