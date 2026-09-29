#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app_binary="$PWD/build/Codex Touch Bar.app/Contents/MacOS/CodexTouchBar"
if [[ ! -x "$app_binary" ]]; then ./scripts/build-app.sh; fi
"$app_binary" --demo --snapshot "$PWD/docs/images/floating-dark.png" --smoke-report "$PWD/build/smoke-demo.json"
"$app_binary" --snapshot "$PWD/docs/images/floating-light.png" --appearance light --smoke-report "$PWD/build/smoke-light.json"
"$app_binary" --smoke-report "$PWD/build/smoke-live.json"
/usr/bin/python3 scripts/test-hooks.py
plutil -lint 'build/Codex Touch Bar.app/Contents/Info.plist'
codesign --verify --deep --strict 'build/Codex Touch Bar.app'
