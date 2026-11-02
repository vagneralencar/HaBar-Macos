#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${HABAR_VERSION:-$(cat VERSION)}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid version" >&2; exit 1; }
BUILD_NUMBER="${HABAR_BUILD_NUMBER:-7}"

echo "🔨 Building HaBar v${VERSION} (macOS Menu Bar App for Home Assistant)..."
BUILD_ARGS=(-c release --arch arm64 --arch x86_64)
if [ -n "${HABAR_BUILD_PATH:-}" ]; then BUILD_ARGS+=(--scratch-path "$HABAR_BUILD_PATH"); fi
if [ "${HABAR_DISABLE_PACKAGE_SANDBOX:-0}" = "1" ]; then BUILD_ARGS+=(--disable-sandbox); fi
BUILD_ARGS+=("$@")
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"

APP_NAME="HaBar.app"
APP_DIR="${HABAR_OUTPUT_DIR:-$(pwd)}/${APP_NAME}"
CONTENTS_DIR="${APP_DIR}/Contents"
MACOS_DIR="${CONTENTS_DIR}/MacOS"
RESOURCES_DIR="${CONTENTS_DIR}/Resources"

rm -rf "${APP_DIR}"
mkdir -p "${MACOS_DIR}" "${RESOURCES_DIR}"

cp "${BIN_DIR}/HaBar" "${MACOS_DIR}/HaBar"
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
    <key>NSBonjourServices</key>
    <array><string>_home-assistant._tcp</string></array>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key>
        <true/>
    </dict>
</dict>
</plist>
EOF

lipo "${MACOS_DIR}/HaBar" -verify_arch arm64
lipo "${MACOS_DIR}/HaBar" -verify_arch x86_64
if [ -n "${HABAR_SIGNING_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$HABAR_SIGNING_IDENTITY" --identifier io.github.habar.menubar "$APP_DIR"
else
    codesign --force --sign - --identifier io.github.habar.menubar "$APP_DIR"
fi
codesign --verify --deep --strict "$APP_DIR"

echo "✅ App bundle generated at: ${APP_DIR}"
