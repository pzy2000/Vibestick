#!/usr/bin/env bash
set -euo pipefail

plist_dst="/Library/LaunchDaemons/com.pzy.vibestick.helper.plist"
helper_dst="/Library/PrivilegedHelperTools/com.pzy.vibestick.helper"

if sudo launchctl print system/com.pzy.vibestick.helper >/dev/null 2>&1; then
  sudo launchctl bootout system "$plist_dst" || true
fi

sudo rm -f "$plist_dst" "$helper_dst"
echo "Uninstalled Vibestick helper."
