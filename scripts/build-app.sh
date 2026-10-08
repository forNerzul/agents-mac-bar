#!/usr/bin/env bash
# Builds dist/AgentsBar.app from the SwiftPM executable.
#
# Usage: scripts/build-app.sh [--universal]
#   --universal       build arm64 + x86_64 (default: native architecture)
# Env:
#   CODESIGN_IDENTITY signing identity (default: "-" = ad-hoc)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ARCH_FLAGS=()
for arg in "$@"; do
  case "$arg" in
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    *) echo "Unknown argument: $arg" >&2; exit 2 ;;
  esac
done

VERSION="$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' Sources/AgentsBarCore/AgentsBarCore.swift)"
if [[ -z "$VERSION" ]]; then
  echo "Could not read AgentsBarCore.version" >&2
  exit 1
fi

swift build -c release --product AgentsBar ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release --product AgentsBar ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

APP="$ROOT/dist/AgentsBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/AgentsBar" "$APP/Contents/MacOS/AgentsBar"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agents Bar</string>
  <key>CFBundleDisplayName</key><string>Agents Bar</string>
  <key>CFBundleIdentifier</key><string>dev.agentsbar.AgentsBar</string>
  <key>CFBundleExecutable</key><string>AgentsBar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign "${CODESIGN_IDENTITY:--}" --timestamp=none "$APP"

echo "Built $APP"
