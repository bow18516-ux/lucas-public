#!/bin/bash
# Foreground launcher for diagnosis: prints stderr and keeps the app attached
# to the terminal so an immediate exit is visible.
cd "$(dirname "$0")/.." || exit 1
pkill -f "Lucas.app/Contents/MacOS/Lucas" 2>/dev/null
sleep 0.3
echo "launching $(pwd)/build/Lucas.app"
./build/Lucas.app/Contents/MacOS/Lucas
echo "app exited with status $?"
echo "--- app log ---"
tail -20 "$HOME/Library/Logs/Lucas/app.log" 2>/dev/null
read -r -p "按回车关闭窗口"
