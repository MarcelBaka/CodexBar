#!/bin/bash
# Direct compiler fallback for CLT installations whose SwiftPM lacks PlatformPath/XCTest.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/local
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
arch_name="$(uname -m)"
core_sources=()
while IFS= read -r source_file; do core_sources+=("$source_file"); done < <(find Sources/CodexTouchBarCore -name '*.swift' | sort)
swiftc -swift-version 5 -O -sdk "$sdk_path" -target "$arch_name-apple-macosx13.0" -emit-library -static -emit-module -module-name CodexTouchBarCore -enable-testing "${core_sources[@]}" -o build/local/libCodexTouchBarCore.a -emit-module-path build/local/CodexTouchBarCore.swiftmodule
if [[ "${1:-}" == "--core-only" ]]; then exit 0; fi
app_sources=()
while IFS= read -r source_file; do app_sources+=("$source_file"); done < <(find Sources/CodexTouchBar -name '*.swift' | sort)
swiftc -swift-version 5 -O -sdk "$sdk_path" -target "$arch_name-apple-macosx13.0" -I build/local -L build/local -lCodexTouchBarCore "${app_sources[@]}" -o build/local/CodexTouchBar
swiftc -swift-version 5 -O -sdk "$sdk_path" -target "$arch_name-apple-macosx13.0" -I build/local -L build/local -lCodexTouchBarCore Sources/CodexTouchBarHook/main.swift -o build/local/CodexTouchBarHook
