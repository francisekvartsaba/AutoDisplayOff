#!/bin/bash
set -euo pipefail
LABEL="com.local.autodisplayoff"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl unload "$PLIST" >/dev/null 2>&1 || true
# The app handles SIGTERM: it switches all displays back on and exits.
pkill -TERM -f ".build/release/AutoDisplayOff" >/dev/null 2>&1 || true
rm -f "$PLIST"

echo "Автозапуск отключён и приложение остановлено."
echo "Если какой-то экран вдруг остался выключенным — запустите приложение ещё раз (оно вернёт экраны при старте)"
echo "или перезагрузите Mac."
