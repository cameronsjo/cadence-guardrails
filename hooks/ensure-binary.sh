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
  if [ "$EXPECTED" = "$CURRENT" ]; then
    # Check if PATH has a newer version (e.g. Homebrew upgrade)
    PATH_BINARY=$(command -v cadence-hooks 2>/dev/null || true)
    if [ -n "$PATH_BINARY" ] && [ "$PATH_BINARY" != "$BINARY" ]; then
      PATH_VERSION=$("$PATH_BINARY" --version 2>/dev/null | awk '{print $2}' || echo "unknown")
      if [ "$PATH_VERSION" != "unknown" ] && [ "$PATH_VERSION" != "$CURRENT" ]; then
        # Use sort -V to compare semver; if PATH is newer, sync it
        NEWER=$(printf '%s\n%s\n' "$CURRENT" "$PATH_VERSION" | sort -V | tail -1)
        if [ "$NEWER" = "$PATH_VERSION" ] && [ "$NEWER" != "$CURRENT" ]; then
          cp "$PATH_BINARY" "$BINARY"
          echo "cadence-hooks synced from PATH: ${CURRENT} → ${PATH_VERSION}" >&2
        fi
      fi
    fi
    exit 0
  fi
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
