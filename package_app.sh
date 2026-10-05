#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

BIN_PATH="$(pwd)/.build/release/AutoDisplayOff"
if [ ! -x "$BIN_PATH" ]; then
    echo "Сначала соберите бинарник: ./build.sh"
    exit 1
fi

APP="AutoDisplayOff.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

cp "$BIN_PATH" "$APP/Contents/MacOS/AutoDisplayOff"
chmod +x "$APP/Contents/MacOS/AutoDisplayOff"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AutoDisplayOff</string>
    <key>CFBundleDisplayName</key>
    <string>AutoDisplayOff</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.autodisplayoff</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleExecutable</key>
    <string>AutoDisplayOff</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo ""
echo "Готово: $(pwd)/$APP"
echo ""
echo "Перетащите его в /Applications (или в Dock) и запускайте двойным кликом / из Dock."
echo "Если это первый запуск и macOS предупредит про неизвестного разработчика:"
echo "  правый клик по AutoDisplayOff.app -> «Открыть» -> подтвердить «Открыть»."
