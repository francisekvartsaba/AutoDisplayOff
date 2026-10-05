#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

BIN_PATH="$(pwd)/.build/release/AutoDisplayOff"
if [ ! -x "$BIN_PATH" ]; then
    echo "Сначала соберите приложение: ./build.sh"
    exit 1
fi

LABEL="com.local.autodisplayoff"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
mkdir -p "$HOME/Library/LaunchAgents"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$BIN_PATH</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/autodisplayoff.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/autodisplayoff.log</string>
</dict>
</plist>
EOF

launchctl unload "$PLIST" >/dev/null 2>&1 || true
launchctl load "$PLIST"

echo "Автозапуск настроен. Приложение уже запущено и появится в строке меню."
echo "Лог: /tmp/autodisplayoff.log"
echo ""
echo "Чтобы отключить автозапуск, выполните: ./uninstall_autostart.sh"
