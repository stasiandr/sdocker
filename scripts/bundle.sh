#!/bin/sh
# Builds the app and wraps it into build/sdocker.app.
set -eu
cd "$(dirname "$0")/.."

swift build -c release
BIN="$(swift build -c release --show-bin-path)/sdocker"

APP=build/sdocker.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/sdocker"

# The icon is an Icon Composer document; actool turns it into Assets.car (Liquid Glass,
# light/dark/tinted) plus an .icns fallback. Absolute paths: actool hands the work to a
# background agent that resolves relative paths from its own folder.
ICON_OUT="$(pwd)/.build/icon"
rm -rf "$ICON_OUT" && mkdir -p "$ICON_OUT"
xcrun actool "$(pwd)/Resources/SDocker.icon" --compile "$ICON_OUT" --platform macosx \
    --minimum-deployment-target 15.0 --app-icon SDocker \
    --output-partial-info-plist "$ICON_OUT/partial.plist" > "$ICON_OUT/actool.log"
cp "$ICON_OUT/Assets.car" "$ICON_OUT/SDocker.icns" "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>sdocker</string>
    <key>CFBundleDisplayName</key><string>sdocker</string>
    <key>CFBundleIdentifier</key><string>dev.stasiandr.sdocker</string>
    <key>CFBundleExecutable</key><string>sdocker</string>
    <key>CFBundleIconFile</key><string>SDocker</string>
    <key>CFBundleIconName</key><string>SDocker</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
