#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${CODEX_TOUCH_BAR_DIRECT_BUILD:-0}" == "1" ]] || ! xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
  echo 'Building with swiftc (Command Line Tools compatible).'
  ./scripts/compile-local.sh
  bin_dir="$PWD/build/local"
else
  swift build -c release
  bin_dir="$(swift build -c release --show-bin-path)"
fi
app_path="$PWD/build/Codex Touch Bar.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources/scripts"
cp "$bin_dir/CodexTouchBar" "$app_path/Contents/MacOS/"
cp "$bin_dir/CodexTouchBarHook" "$app_path/Contents/MacOS/"
cp Sources/CodexTouchBar/Resources/Info.plist "$app_path/Contents/Info.plist"
cp scripts/manage-hooks.py "$app_path/Contents/Resources/scripts/"
if [[ -f Sources/CodexTouchBar/Resources/AppIcon.icns ]]; then cp Sources/CodexTouchBar/Resources/AppIcon.icns "$app_path/Contents/Resources/"; fi
/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$app_path/Contents/Info.plist" >/dev/null
codesign --force --sign "${CODEX_TOUCH_BAR_SIGN_IDENTITY:--}" "$app_path/Contents/MacOS/CodexTouchBarHook"
codesign --force --sign "${CODEX_TOUCH_BAR_SIGN_IDENTITY:--}" "$app_path"
codesign --verify --deep --strict "$app_path"
echo "Built: $app_path"
