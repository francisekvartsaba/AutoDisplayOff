#!/bin/bash
set -euo pipefail
LABEL="com.local.autodisplayoff"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl unload "$PLIST" >/dev/null 2>&1 || true
pkill -f ".build/release/AutoDisplayOff" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "Автозапуск отключён и приложение остановлено."
echo "Если экран ноутбука вдруг остался выключенным — отключите/переподключите внешний монитор,"
echo "это заставит macOS переинициализировать дисплеи."
