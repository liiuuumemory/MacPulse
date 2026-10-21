#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUTPUT_DIR="${1:-$HOME/Applications}"
BUILD_DIR="${MACPULSE_BUILD_DIR:-${TMPDIR:-/tmp}/macpulse-build-$UID}"
STAGE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/macpulse-stage.XXXXXX")"
APP_DIR="$STAGE_DIR/MacPulse.app"
mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
export CLANG_MODULE_CACHE_PATH="$BUILD_DIR/ModuleCache"
clang -O2 -target arm64-apple-macos14.0 -c "$PROJECT_DIR/Source/Sensors.c" -o "$BUILD_DIR/Sensors.o"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 \
  -module-cache-path "$BUILD_DIR/ModuleCache" \
  -import-objc-header "$PROJECT_DIR/Source/Sensors.h" \
  "$PROJECT_DIR/Source/Metrics.swift" "$PROJECT_DIR/Source/Monitor.swift" \
  "$PROJECT_DIR/Source/MenuBar.swift" "$PROJECT_DIR/Source/Preferences.swift" \
  "$PROJECT_DIR/Source/AIUsageTests.swift" "$PROJECT_DIR/Source/AIUsage.swift" "$PROJECT_DIR/Source/AgentLogs.swift" "$PROJECT_DIR/Source/QuotaClient.swift" "$PROJECT_DIR/Source/AIUsageViews.swift" \
  "$PROJECT_DIR/Source/Alerts.swift" "$PROJECT_DIR/Source/UsageSync.swift" "$PROJECT_DIR/Source/Updater.swift" \
  "$PROJECT_DIR/Source/Panel.swift" "$PROJECT_DIR/Source/main.swift" \
  "$BUILD_DIR/Sensors.o" -framework AppKit -framework SwiftUI -framework IOKit \
  -framework ServiceManagement -framework UserNotifications -framework Security -framework LocalAuthentication -lsqlite3 -lIOReport -o "$APP_DIR/Contents/MacOS/MacPulse"
cp "$PROJECT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
# Lets the update check offer "git pull && bash build.sh" for this checkout. Local build product only.
plutil -insert MacPulseSourcePath -string "$PROJECT_DIR" "$APP_DIR/Contents/Info.plist"
if [ -f "$PROJECT_DIR/AppIcon.icns" ]; then cp "$PROJECT_DIR/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"; fi
xattr -cr "$APP_DIR"
codesign --force --sign - --identifier local.macpulse.monitor "$APP_DIR"
codesign --verify --strict "$APP_DIR"
mkdir -p "$OUTPUT_DIR"
ditto --norsrc --noextattr "$APP_DIR" "$OUTPUT_DIR/MacPulse.app"
# File Provider managed folders can add Finder metadata during the copy.
# Verify the delivered bundle, not just the temporary build product.
xattr -cr "$OUTPUT_DIR/MacPulse.app"
codesign --force --sign - --identifier local.macpulse.monitor "$OUTPUT_DIR/MacPulse.app"
codesign --verify --strict "$OUTPUT_DIR/MacPulse.app"
printf 'Built: %s\n' "$OUTPUT_DIR/MacPulse.app"
