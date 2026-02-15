#!/bin/bash
# Auto-sync btsave sources to GitHub if changes detected
REPO=/home/xou/Hedge
DASH=/home/xou/hedge-dashboard
GRIDWS=/home/xou/deribit-grid-ws

# Sync live sources
cp "$DASH/server.js" "$REPO/dashboard/server.js"
cp "$DASH/public/index.html" "$REPO/dashboard/public/index.html"
cp "$DASH/public/login.html" "$REPO/dashboard/public/login.html"
cp "$DASH/public/logo.svg" "$REPO/dashboard/public/logo.svg" 2>/dev/null
cp "$GRIDWS/grid-ws.js" "$REPO/grid-ws/grid-ws.js"

cd "$REPO" || exit 1

# Check for changes
if git diff --quiet && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  echo "No changes detected"
  exit 0
fi

git add -A
git commit -m "auto-sync $(date -u +%Y-%m-%d\ %H:%M)"
git push

echo "Pushed at $(date -u)"
