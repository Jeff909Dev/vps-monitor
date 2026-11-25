#!/usr/bin/env bash
# Builds build/VPS Monitor.app (at the repo root) from the SwiftPM executable; no Xcode project. One universal
# binary (arm64 and x86_64), ad-hoc signed, versioned from VERSION, carrying vpsmon-install.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(tr -d '[:space:]' < ../VERSION)"
ARCHS=(--arch arm64 --arch x86_64)

swift build -c release "${ARCHS[@]}" --product VPSMonitor
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/VPSMonitor"
APP="../build/VPS Monitor.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/VPSMonitor"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# The app installs the vpsmon it carries, so the server and the app always share a version.
if [[ -x ../scripts/make-installer.sh ]]; then
  ../scripts/make-installer.sh "$APP/Contents/Resources/vpsmon-install.sh"
else
  echo "warning: ../scripts/make-installer.sh not found; this app can't install vpsmon on a server" >&2
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>VPSMonitor</string>
  <key>CFBundleIdentifier</key><string>com.jeff909dev.VPSMonitor</string>
  <key>CFBundleName</key><string>VPS Monitor</string>
  <key>CFBundleDisplayName</key><string>VPS Monitor</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP ($VERSION, $(lipo -archs "$APP/Contents/MacOS/VPSMonitor"))"
