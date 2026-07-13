#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="codex监测"
SOURCE_APP="$ROOT_DIR/dist/$APP_NAME.app"
INSTALL_DIR="${CODEX_NOTCH_INSTALL_DIR:-$HOME/Applications}"
TARGET_APP="$INSTALL_DIR/$APP_NAME.app"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Missing $SOURCE_APP. Run ./scripts/build-app.sh first." >&2
  exit 1
fi

pkill -x CodexNotch 2>/dev/null || true
mkdir -p "$INSTALL_DIR"
rm -rf "$TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"
xattr -dr com.apple.quarantine "$TARGET_APP" 2>/dev/null || true
if ! open "$TARGET_APP"; then
  sleep 1
  open "$TARGET_APP"
fi

echo "Installed $TARGET_APP"
