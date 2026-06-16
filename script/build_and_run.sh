#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DERIVED_DATA="$ROOT/.build/XcodeDerivedData"
PROJECT="$ROOT/Aiassistant.xcodeproj"
SCHEME="Aiassistant"
APP="$DERIVED_DATA/Build/Products/Debug/Aiassistant.app"
EXECUTABLE="$APP/Contents/MacOS/Aiassistant"
LOG_FILE="/tmp/aiassistant-lldb-live.log"

pkill -f "lldb.*Aiassistant" 2>/dev/null || true
pkill -x Aiassistant 2>/dev/null || true
sleep 1
if pgrep -x Aiassistant >/dev/null; then
  pkill -9 -x Aiassistant 2>/dev/null || true
fi

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" \
  build

/usr/bin/open -n "$APP" --args --show-settings

sleep 2

if ! pgrep -x Aiassistant >/dev/null; then
  nohup "$EXECUTABLE" --show-settings >"$LOG_FILE" 2>&1 &
fi

if [[ "${1:-}" == "--verify" ]]; then
  sleep 4
  pgrep -x Aiassistant >/dev/null
fi
