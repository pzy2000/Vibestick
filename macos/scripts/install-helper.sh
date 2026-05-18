#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
macos_root="$repo_root/macos"
helper_src="${1:-$macos_root/.build/release/VibestickHelper}"
helper_dst="/Library/PrivilegedHelperTools/com.pzy.vibestick.helper"
plist_src="$macos_root/packaging/LaunchDaemons/com.pzy.vibestick.helper.plist"
plist_dst="/Library/LaunchDaemons/com.pzy.vibestick.helper.plist"

if [[ ! -x "$helper_src" ]]; then
  echo "Helper binary not found at $helper_src. Run: swift build -c release" >&2
  exit 2
fi

sudo install -d -o root -g wheel -m 755 /Library/PrivilegedHelperTools
sudo install -o root -g wheel -m 755 "$helper_src" "$helper_dst"
sudo install -o root -g wheel -m 644 "$plist_src" "$plist_dst"

if sudo launchctl print system/com.pzy.vibestick.helper >/dev/null 2>&1; then
  sudo launchctl bootout system "$plist_dst" || true
fi
sudo launchctl bootstrap system "$plist_dst"
sudo launchctl enable system/com.pzy.vibestick.helper

echo "Installed Vibestick helper at $helper_dst"
