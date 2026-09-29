#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ ! -d 'build/Codex Touch Bar.app' ]]; then ./scripts/build-app.sh; fi
install_root="${1:-/Applications}"
mkdir -p "$install_root"
if [[ -e "$install_root/Codex Touch Bar.app" ]]; then
  echo "An app already exists at $install_root/Codex Touch Bar.app. Quit it and move it aside before installing." >&2
  exit 1
fi
ditto 'build/Codex Touch Bar.app' "$install_root/Codex Touch Bar.app"
echo "Installed: $install_root/Codex Touch Bar.app"
