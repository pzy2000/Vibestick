#!/usr/bin/env bash
set -euo pipefail

mode="${1:-dev}"
case "$mode" in
  dev|release) ;;
  *)
    echo "Usage: $0 [dev|release]" >&2
    exit 64
    ;;
esac

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
macos_root="$repo_root/macos"
dist="$macos_root/dist"
app="$dist/Vibestick.app"
asset_root="$dist/packaging-assets"
iconset="$asset_root/Vibestick.iconset"
icon="$asset_root/Vibestick.icns"

cd "$macos_root"
swift build -c release

rm -rf "$app" "$dist/vibestickctl"
mkdir -p "$app/Contents/MacOS" \
  "$app/Contents/Resources" \
  "$app/Contents/Library/LaunchDaemons" \
  "$app/Contents/Library/PrivilegedHelperTools" \
  "$asset_root"

if [[ ! -f "$icon" ]]; then
  "$macos_root/scripts/generate-packaging-assets.swift" iconset "$iconset"
  iconutil -c icns "$iconset" -o "$icon"
fi

cp "$macos_root/packaging/AppBundle/Info.plist" "$app/Contents/Info.plist"
cp "$icon" "$app/Contents/Resources/Vibestick.icns"
cp "$macos_root/.build/release/VibestickApp" "$app/Contents/MacOS/VibestickApp"
cp "$macos_root/.build/release/VibestickDeviceWatcher" "$app/Contents/MacOS/VibestickDeviceWatcher"
cp "$macos_root/.build/release/vibestickctl" "$dist/vibestickctl"
cp "$macos_root/.build/release/VibestickHelper" "$app/Contents/Library/PrivilegedHelperTools/com.pzy.vibestick.helper"
cp "$macos_root/packaging/LaunchDaemons/com.pzy.vibestick.helper.plist" "$app/Contents/Library/LaunchDaemons/com.pzy.vibestick.helper.plist"

resource_bundle="$(find "$macos_root/.build" -path '*/release/VibestickMac_VibestickApp.bundle' -type d | head -n 1)"
if [[ -z "$resource_bundle" ]]; then
  echo "SwiftPM resource bundle for VibestickApp was not found." >&2
  exit 2
fi
ditto --norsrc "$resource_bundle" "$app/Contents/Resources/$(basename "$resource_bundle")"

clear_app_xattrs() {
  if command -v xattr >/dev/null 2>&1; then
    for _ in 1 2 3; do
      xattr -cr "$app" || true
      find "$app" -exec xattr -d 'com.apple.fileprovider.fpfs#P' {} + 2>/dev/null || true
      find "$app" -exec xattr -d com.apple.FinderInfo {} + 2>/dev/null || true
      find "$app" -exec xattr -d com.apple.ResourceFork {} + 2>/dev/null || true
      if ! xattr -lr "$app" 2>/dev/null | grep -q "com.apple.FinderInfo"; then
        break
      fi
      sleep 0.1
    done
  fi
}

clear_app_xattrs

if [[ "$mode" == "dev" ]]; then
  codesign --force --deep --sign - "$app"
  clear_app_xattrs
  codesign --force --sign - "$dist/vibestickctl"
else
  : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION for release signing.}"
  codesign --force --options runtime --timestamp --deep --sign "$DEVELOPER_ID_APPLICATION" "$app"
  clear_app_xattrs
  codesign --force --options runtime --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$dist/vibestickctl"
fi

echo "$app"
