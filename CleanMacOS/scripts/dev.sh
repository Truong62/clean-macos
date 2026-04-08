#!/bin/bash
# Auto-rebuild & relaunch khi save file
# Usage: ./scripts/dev.sh

APP="CleanMacOS"
cd "$(dirname "$0")/.."

rebuild() {
    echo "$(date +%H:%M:%S) → Building..."
    pkill -x "$APP" 2>/dev/null
    if swift build 2>&1 | tail -1; then
        echo "$(date +%H:%M:%S) → Launching..."
        .build/debug/"$APP" &
    else
        echo "$(date +%H:%M:%S) ✗ Build failed"
    fi
}

# Initial build
rebuild

# Watch for changes
echo "Watching Sources/ for changes... (Ctrl+C to stop)"
fswatch -o Sources/ | while read; do
    rebuild
done
