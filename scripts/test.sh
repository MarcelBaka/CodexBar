#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
./scripts/compile-local.sh --core-only
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
swiftc -swift-version 5 -sdk "$sdk_path" -target "$(uname -m)-apple-macosx13.0" -I build/local -L build/local -lCodexTouchBarCore Tests/Checks/main.swift -o build/local/CodexTouchBarChecks
build/local/CodexTouchBarChecks
if xcrun --find xctest >/dev/null 2>&1 && xcrun --sdk macosx --show-sdk-platform-path >/dev/null 2>&1; then
  swift test
else
  echo 'XCTest unavailable in this Command Line Tools installation; portable core checks completed.'
fi
