#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
macos_root="$repo_root/macos"
ctl="$macos_root/dist/vibestickctl"

if [[ ! -x "$ctl" ]]; then
  echo "vibestickctl not found. Run: macos/scripts/build-release.sh dev" >&2
  exit 2
fi

"$ctl" device-watcher uninstall
