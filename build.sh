#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

echo "Building AutoDisplayOff (release)…"
swift build -c release

BIN_PATH="$(pwd)/.build/release/AutoDisplayOff"
echo ""
echo "Готово. Бинарник: $BIN_PATH"
echo ""
echo "Запустить сейчас (в текущем терминале, Ctrl+C чтобы остановить):"
echo "  \"$BIN_PATH\""
echo ""
echo "Чтобы приложение запускалось автоматически при входе в систему, запустите:"
echo "  ./install_autostart.sh"
