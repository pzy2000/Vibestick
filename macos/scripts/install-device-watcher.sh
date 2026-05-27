#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
macos_root="$repo_root/macos"
app_path="${1:-$macos_root/dist/Vibestick.app}"
ctl="$macos_root/dist/vibestickctl"

if [[ ! -x "$ctl" || ! -d "$app_path" ]]; then
  echo "Built app or vibestickctl not found. Run: macos/scripts/build-release.sh dev" >&2
  exit 2
fi

"$ctl" device-watcher install --app-path "$app_path"
