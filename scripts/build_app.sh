#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="1.7.0"
BUILD_NUMBER="7"

echo "🔨 Building HaBar v${VERSION} (macOS Menu Bar App for Home Assistant)..."
swift build -c release

APP_NAME="HaBar.app"
APP_DIR="$(pwd)/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp ".build/release/HaBar" "${MACOS_DIR}/HaBar"
chmod +x "${MACOS_DIR}/HaBar"

if [ -f "Assets/AppIcon.icns" ]; then
    cp "Assets/AppIcon.icns" "${RESOURCES_DIR}/AppIcon.icns"
fi

cat > "${CONTENTS_DIR}/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>pt_BR</string>
    <key>CFBundleExecutable</key>
    <string>HaBar</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>io.github.habar.menubar</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>HaBar</string>
    <key>CFBundleDisplayName</key>
    <string>HaBar</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${BUILD_NUMBER}</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>HaBar connects to your Home Assistant server on the local network to control scenes, lights, and smart devices.</string>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsArbitraryLoads</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

codesign --force --deep --sign - --identifier io.github.habar.menubar "${APP_DIR}" 2>/dev/null || true

echo "✅ App bundle generated at: ${APP_DIR}"
